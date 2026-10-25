-- Loterij met de barkaarten (Beheer → Loterij). Een beheerder kiest een periode en hoe
-- de loten verdeeld worden, en trekt een winnende kaart. Komen telt, niet drinken:
--   dagen        1 lot per baravond dat met de kaart is betaald (met een maximum)
--   gelijk       1 lot per kaart waarmee in de periode is betaald
--   opwaarderen  1 lot per € 10 dat op de kaart is gezet (met een maximum)
-- Een baravond loopt tot 06:00, net als in het rapport. Geblokkeerde en verwijderde
-- kaarten doen niet mee; de beheerder kan kaarten uitsluiten (bijv. van jeugdleden).
-- Elke trekking wordt bewaard en is niet te veranderen. Een prijs kan als tegoed op de
-- winnende kaart (soort 'prijs'): geen geld in de kas, wel in het rapport en het logboek.

alter table public.kaart_mutaties drop constraint kaart_mutaties_soort_check;
alter table public.kaart_mutaties add constraint kaart_mutaties_soort_check
  check (soort in ('opwaardering', 'betaling', 'annulering', 'overzetting', 'vervallen', 'prijs'));

create table public.loterij_trekkingen (
  id              bigint generated always as identity primary key,
  ts              timestamptz not null default now(),
  door            uuid references public.profielen,
  door_naam       text,
  van             date not null,
  tot             date not null,
  manier          text not null check (manier in ('dagen', 'gelijk', 'opwaarderen')),
  max_loten       int not null,
  uitgesloten     int[] not null default '{}',
  deelnemers      int not null,
  loten           int not null,
  winnaar_kaart   bigint not null references public.kaarten,
  winnaar_nummer  int not null,
  winnaar_loten   int not null,
  prijs_cent      int not null default 0 check (prijs_cent between 0 and 100000),
  omschrijving    text check (omschrijving is null or length(omschrijving) <= 80)
);
alter table public.loterij_trekkingen enable row level security;
create policy lezen on public.loterij_trekkingen for select to authenticated using ((select public.is_beheerder()));
revoke all on public.loterij_trekkingen from anon, authenticated;
grant select on public.loterij_trekkingen to authenticated;

-- Loten per kaart. Volgorde op kaartnummer, zodat een trekking na te rekenen is.
create function public._loterij_loten(p_van date, p_tot date, p_manier text, p_max int, p_uitgesloten int[])
returns table (kaart_id bigint, nummer int, naam text, loten int)
language sql stable security definer set search_path = '' as $$
  with m as (
    select m.kaart_id, m.soort, m.bedrag_cent,
           ((m.ts at time zone 'Europe/Amsterdam') - interval '6 hours')::date as bardag
    from public.kaart_mutaties m
    where m.ts >= (p_van::timestamp + interval '6 hours') at time zone 'Europe/Amsterdam'
      and m.ts <  ((p_tot + 1)::timestamp + interval '6 hours') at time zone 'Europe/Amsterdam'
  ), l as (
    select kaart_id, case p_manier
      when 'dagen' then count(distinct bardag) filter (where soort = 'betaling')
      when 'gelijk' then least(count(*) filter (where soort = 'betaling'), 1)
      when 'opwaarderen' then coalesce(sum(bedrag_cent) filter (where soort = 'opwaardering'), 0) / 1000
    end::int as n
    from m group by kaart_id
  )
  select k.id, k.nummer, k.naam, least(l.n, greatest(p_max, 1))
  from l join public.kaarten k on k.id = l.kaart_id
  where l.n > 0 and not k.geblokkeerd and k.verwijderd_ts is null
    and not (k.nummer = any(coalesce(p_uitgesloten, '{}')))
  order by k.nummer
$$;
revoke execute on function public._loterij_loten(date, date, text, int, int[]) from public, anon, authenticated;

create function public._loterij_controle(p_van date, p_tot date, p_manier text, p_max int) returns void
language plpgsql immutable as $$
begin
  if p_van is null or p_tot is null or p_tot < p_van then raise exception 'Kies een periode'; end if;
  if p_tot - p_van > 400 then raise exception 'Kies een periode van hoogstens een jaar'; end if;
  if p_manier is null or p_manier not in ('dagen', 'gelijk', 'opwaarderen') then raise exception 'Kies hoe de loten verdeeld worden'; end if;
  if p_max is null or p_max not between 1 and 100 then raise exception 'Kies een maximum van 1 tot 100 loten per kaart'; end if;
end $$;

-- Wie doet mee en met hoeveel loten, zonder te trekken.
create function public.loterij_voorbeeld(p_van date, p_tot date, p_manier text, p_max int, p_uitgesloten int[] default '{}')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._eis('beheerder');
  perform public._loterij_controle(p_van, p_tot, p_manier, p_max);
  return (
    select jsonb_build_object(
      'deelnemers', count(*), 'loten', coalesce(sum(loten), 0),
      'lijst', coalesce(jsonb_agg(jsonb_build_object('nummer', nummer, 'naam', naam, 'loten', loten) order by loten desc, nummer), '[]'))
    from public._loterij_loten(p_van, p_tot, p_manier, p_max, p_uitgesloten));
end $$;

create function public.loterij_trekken(p_van date, p_tot date, p_manier text, p_max int, p_uitgesloten int[] default '{}',
                                       p_prijs_cent int default 0, p_omschrijving text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  totaal int; deelnemers int; lot bigint; w record; t public.loterij_trekkingen; nummers int[];
begin
  perform public._eis('beheerder');
  perform public._loterij_controle(p_van, p_tot, p_manier, p_max);
  if coalesce(p_prijs_cent, 0) not between 0 and 100000 then raise exception 'Kies een prijs tot € 1.000'; end if;
  if length(trim(coalesce(p_omschrijving, ''))) > 80 then raise exception 'Beschrijf de prijs in hoogstens 80 tekens'; end if;

  select count(*), coalesce(sum(loten), 0) into deelnemers, totaal
  from public._loterij_loten(p_van, p_tot, p_manier, p_max, p_uitgesloten);
  if totaal = 0 then raise exception 'Er doen geen kaarten mee in deze periode'; end if;

  -- Een echt willekeurig lot (geen gewone random()): 0 .. totaal - 1, dan de kaart waar dat lot bij hoort.
  lot := mod(mod(('x' || encode(extensions.gen_random_bytes(8), 'hex'))::bit(64)::bigint, totaal) + totaal, totaal);
  select * into w from (
    select l.*, sum(l.loten) over (order by l.nummer) as tot_en_met
    from public._loterij_loten(p_van, p_tot, p_manier, p_max, p_uitgesloten) l
  ) x where x.tot_en_met > lot order by x.nummer limit 1;

  insert into public.loterij_trekkingen (door, door_naam, van, tot, manier, max_loten, uitgesloten, deelnemers, loten,
                                         winnaar_kaart, winnaar_nummer, winnaar_loten, prijs_cent, omschrijving)
  values (auth.uid(), (select naam from public.profielen where id = auth.uid()), p_van, p_tot, p_manier, p_max,
          coalesce(p_uitgesloten, '{}'), deelnemers, totaal, w.kaart_id, w.nummer, w.loten,
          coalesce(p_prijs_cent, 0), nullif(trim(coalesce(p_omschrijving, '')), ''))
  returning * into t;

  if t.prijs_cent > 0 then
    update public.kaarten set saldo_cent = saldo_cent + t.prijs_cent where id = w.kaart_id;
    insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, dienst_id, door)
    values (w.kaart_id, t.prijs_cent, 'prijs', (select id from public.diensten where gesloten_ts is null limit 1), auth.uid());
  end if;

  perform public._log('loterij', jsonb_build_object('kaart', w.nummer, 'loten', w.loten, 'van_loten', totaal,
    'deelnemers', deelnemers, 'prijs_cent', t.prijs_cent, 'omschrijving', t.omschrijving));

  -- Voor de trekking op het scherm: een paar nummers die meedoen om langs te laten rollen.
  select array_agg(nummer) into nummers from (
    select nummer from public._loterij_loten(p_van, p_tot, p_manier, p_max, p_uitgesloten) order by random() limit 30) x;
  return jsonb_build_object('id', t.id, 'nummer', w.nummer, 'naam', w.naam, 'loten', w.loten,
    'totaal', totaal, 'deelnemers', deelnemers, 'prijs_cent', t.prijs_cent, 'omschrijving', t.omschrijving, 'nummers', nummers);
end $$;

revoke execute on function public.loterij_voorbeeld(date, date, text, int, int[]),
  public.loterij_trekken(date, date, text, int, int[], int, text) from public, anon;
grant execute on function public.loterij_voorbeeld(date, date, text, int, int[]),
  public.loterij_trekken(date, date, text, int, int[], int, text) to authenticated;
