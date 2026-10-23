-- Te weinig wisselgeld: bij contant betalen kan wat er terug moet als tegoed
-- op een barkaart (p_betalingen: {"methode": "contant", "gegeven_cent": 5000, "rest_kaart": "K7MQ-3XRP"}).
-- De app waarschuwt als het wisselgeld meer is dan er volgens de kassa in de la zit.

alter table public.betalingen
  add column op_kaart_id bigint references public.kaarten,
  add column op_kaart_cent int check (op_kaart_cent > 0),
  add column op_kaart_saldo_na int;

create or replace function public._afrekenen(p_regels jsonb default '[]', p_betalingen jsonb default '[]', p_rekening_id bigint default null,
                                              p_verwacht_cent int default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_dienst bigint;
  v_id     bigint;
  v_rek    public.rekeningen;
  v_totaal int;
  v_rest   int;
  v_kaart  public.kaarten;
  v_bedrag int;
  v_b      jsonb;
  v_n      int;
  v_gegeven int;
  v_lid    public.leden;
  v_over   int := 0;
  v_op     public.kaarten;
begin
  perform public._eis('medewerker');
  v_dienst := public._open_dienst();

  if jsonb_typeof(p_betalingen) is distinct from 'array' or jsonb_typeof(p_regels) is distinct from 'array' then
    raise exception 'Ongeldige bestelling';
  end if;

  insert into public.verkopen (door, door_naam, dienst_id)
  values (auth.uid(), (select naam from public.profielen where id = auth.uid()), v_dienst)
  returning id into v_id;

  if p_rekening_id is not null then
    select * into v_rek from public.rekeningen where id = p_rekening_id for update;
    if not found or not v_rek.open then
      raise exception 'Deze rekening is al afgerekend of bestaat niet';
    end if;
    insert into public.verkoop_regels (verkoop_id, product_id, naam, prijs_cent, aantal)
    select v_id, product_id, naam, prijs_cent, sum(aantal)
    from public.rekening_regels where rekening_id = p_rekening_id
    group by product_id, naam, prijs_cent order by min(id);
    update public.rekeningen set open = false, gesloten_ts = now() where id = p_rekening_id;
    update public.verkopen set rekening_naam = v_rek.naam where id = v_id;
  else
    if exists (select 1 from jsonb_array_elements(p_regels) e
               where coalesce((e ->> 'aantal')::int, 0) not between 1 and 999) then
      raise exception 'Ongeldig aantal in de bestelling';
    end if;
    with r as (
      select (e ->> 'product_id')::bigint as pid, sum((e ->> 'aantal')::int) as aantal, min(ord) as ord
      from jsonb_array_elements(p_regels) with ordinality as x(e, ord) group by 1
    )
    insert into public.verkoop_regels (verkoop_id, product_id, naam, prijs_cent, aantal)
    select v_id, p.id, p.naam, p.prijs_cent, r.aantal
    from r join public.producten p on p.id = r.pid and p.actief and not p.verwijderd
    order by r.ord;
    get diagnostics v_n = row_count;
    if v_n <> (select count(distinct e ->> 'product_id') from jsonb_array_elements(p_regels) e) then
      raise exception 'Een product in de bestelling is niet meer beschikbaar';
    end if;
    -- Voorraad afboeken (bij een rekening gebeurde dat al bij het opschrijven).
    with r as (select product_id, sum(aantal) as a from public.verkoop_regels where verkoop_id = v_id group by 1),
    u as (update public.producten p set voorraad = p.voorraad - r.a from r
          where p.id = r.product_id and p.voorraad_bijhouden returning p.id, r.a)
    insert into public.voorraad_mutaties (product_id, aantal, reden, verkoop_id, door)
    select id, -a, 'verkoop', v_id, auth.uid() from u;
  end if;

  select coalesce(sum(prijs_cent * aantal), 0) into v_totaal from public.verkoop_regels where verkoop_id = v_id;
  if not exists (select 1 from public.verkoop_regels where verkoop_id = v_id) then
    raise exception 'De bestelling is leeg';
  end if;
  -- Is het bedrag intussen veranderd (iemand boekte bij op de rekening, of een prijs
  -- werd aangepast)? Dan niet afrekenen: er is al gepind of afgeteld voor het oude bedrag.
  if p_verwacht_cent is not null and p_verwacht_cent <> v_totaal then
    raise exception 'Het bedrag is intussen veranderd: het is nu € %. Controleer de bestelling en reken opnieuw af.',
      to_char(v_totaal / 100.0, 'FM999990.00');
  end if;
  update public.verkopen set totaal_cent = v_totaal where id = v_id;
  v_rest := v_totaal;

  -- Kaart eerst.
  if (select count(*) from jsonb_array_elements(p_betalingen) e where e ->> 'methode' = 'kaart') > 1 then
    raise exception 'Je kunt met maar één kaart tegelijk betalen';
  end if;
  select e into v_b from jsonb_array_elements(p_betalingen) e where e ->> 'methode' = 'kaart';
  if v_b is not null then
    select * into v_kaart from public.kaarten where id = public._zoek_kaart(v_b ->> 'kaart', true) for update;
    if v_kaart.geblokkeerd then raise exception 'Kaart % is geblokkeerd', v_kaart.nummer; end if;
    v_bedrag := least(v_kaart.saldo_cent, v_rest);
    if v_bedrag <= 0 and v_rest > 0 then raise exception 'Er staat geen tegoed op kaart %', v_kaart.nummer; end if;
    update public.kaarten set saldo_cent = saldo_cent - v_bedrag where id = v_kaart.id;
    insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, verkoop_id, dienst_id, door)
    values (v_kaart.id, -v_bedrag, 'betaling', v_id, v_dienst, auth.uid());
    insert into public.betalingen (verkoop_id, methode, bedrag_cent, kaart_id, kaart_saldo_na)
    values (v_id, 'kaart', v_bedrag, v_kaart.id, v_kaart.saldo_cent - v_bedrag);
    v_rest := v_rest - v_bedrag;
  end if;

  -- Restant met contant of pin.
  select count(*) into v_n from jsonb_array_elements(p_betalingen) e where e ->> 'methode' <> 'kaart';
  if v_rest > 0 then
    if v_n <> 1 then raise exception 'Kies hoe er betaald wordt (nog % open)', to_char(v_rest / 100.0, 'FM9990.00'); end if;
    select e into v_b from jsonb_array_elements(p_betalingen) e where e ->> 'methode' <> 'kaart';
    if v_b ->> 'methode' = 'contant' then
      v_gegeven := coalesce((v_b ->> 'gegeven_cent')::int, v_rest);
      if v_gegeven < v_rest then raise exception 'Er is te weinig gegeven'; end if;
      -- Te weinig wisselgeld in de la: wat over is als tegoed op een barkaart.
      -- Dat is een gewone contante opwaardering (telt mee in de la) en blijft
      -- staan als de bon later wordt geannuleerd.
      if nullif(trim(v_b ->> 'rest_kaart'), '') is not null and v_gegeven > v_rest then
        perform public._methode_aan('kaart');
        v_over := v_gegeven - v_rest;
        if v_over > 50000 then raise exception 'Je kunt hoogstens € 500 op een kaart zetten'; end if;
        select * into v_op from public.kaarten where id = public._zoek_kaart(v_b ->> 'rest_kaart', true) for update;
        if v_op.geblokkeerd then raise exception 'Kaart % is geblokkeerd', v_op.nummer; end if;
        update public.kaarten set saldo_cent = saldo_cent + v_over where id = v_op.id;
        insert into public.kaart_mutaties (kaart_id, bedrag_cent, soort, methode, verkoop_id, dienst_id, door)
        values (v_op.id, v_over, 'opwaardering', 'contant', v_id, v_dienst, auth.uid());
      end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, gegeven_cent, wisselgeld_cent, op_kaart_id, op_kaart_cent, op_kaart_saldo_na)
      values (v_id, 'contant', v_rest, v_gegeven, v_gegeven - v_rest - v_over, v_op.id, nullif(v_over, 0), v_op.saldo_cent + v_over);
    elsif v_b ->> 'methode' = 'pin' then
      insert into public.betalingen (verkoop_id, methode, bedrag_cent) values (v_id, 'pin', v_rest);
    elsif v_b ->> 'methode' = 'lat' then
      -- Op de streeplijst van een lid: later afrekenen (lat_afbetalen).
      select * into v_lid from public.leden where id = (v_b ->> 'lid')::bigint;
      if not found then raise exception 'Kies een lid voor de streeplijst'; end if;
      if not v_lid.actief then raise exception '% staat niet meer op de streeplijst', v_lid.naam; end if;
      insert into public.betalingen (verkoop_id, methode, bedrag_cent, lid_id) values (v_id, 'lat', v_rest, v_lid.id);
    else
      raise exception 'Onbekende betaalmethode';
    end if;
  end if;

  return public.bon(v_id);
end $$;

-- Bon: met de kaart waar het wisselgeld op is gezet.
create or replace function public.bon(p_verkoop_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', v.id, 'bonnummer', v.bonnummer, 'ts', v.ts, 'door_naam', v.door_naam,
    'rekening_naam', v.rekening_naam, 'totaal_cent', v.totaal_cent,
    'geannuleerd', v.geannuleerd, 'winkel', (select naam from public.instellingen),
    'regels', coalesce((select jsonb_agg(jsonb_build_object('naam', r.naam, 'prijs_cent', r.prijs_cent, 'aantal', r.aantal) order by r.id)
                        from public.verkoop_regels r where r.verkoop_id = v.id), '[]'),
    'betalingen', coalesce((select jsonb_agg(jsonb_build_object('methode', b.methode, 'bedrag_cent', b.bedrag_cent,
                              'kaart_nummer', k.nummer, 'kaart_saldo_na', b.kaart_saldo_na,
                              'gegeven_cent', b.gegeven_cent, 'wisselgeld_cent', b.wisselgeld_cent,
                              'lid_naam', l.naam,
                              'op_kaart_nummer', ok.nummer, 'op_kaart_cent', b.op_kaart_cent, 'op_kaart_saldo_na', b.op_kaart_saldo_na) order by b.id)
                            from public.betalingen b left join public.kaarten k on k.id = b.kaart_id
                            left join public.leden l on l.id = b.lid_id
                            left join public.kaarten ok on ok.id = b.op_kaart_id
                            where b.verkoop_id = v.id), '[]'))
  from public.verkopen v where v.id = p_verkoop_id
$$;
