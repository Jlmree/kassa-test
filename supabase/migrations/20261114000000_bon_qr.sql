-- Bon voor de klant via een QR-code: na het afrekenen toont de kassa een QR-code, de klant
-- scant die met de eigen telefoon en ziet de bon (en kan hem bewaren). Geen inloggen nodig.
-- Elke bon heeft daarvoor een eigen geheime code van 24 tekens die niet te raden is; wie de
-- code niet heeft, ziet de bon niet. Een bon is 90 dagen te bekijken. Verkeerde codes tellen
-- mee voor dezelfde blokkade als op de saldo-pagina.

alter table public.verkopen add column deel_code text unique default encode(extensions.gen_random_bytes(12), 'hex');

create or replace function public.bon(p_verkoop_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', v.id, 'bonnummer', v.bonnummer, 'ts', v.ts, 'door_naam', v.door_naam,
    'rekening_naam', v.rekening_naam, 'totaal_cent', v.totaal_cent,
    'geannuleerd', v.geannuleerd, 'winkel', (select naam from public.instellingen),
    'btw_aan', (select btw_aan from public.instellingen), 'btw_nummer', (select btw_nummer from public.instellingen),
    'deel_code', v.deel_code,
    'regels', coalesce((select jsonb_agg(jsonb_build_object('naam', r.naam, 'prijs_cent', r.prijs_cent, 'aantal', r.aantal,
                                                            'btw_pct', coalesce(r.btw_pct, p.btw_pct, 21)) order by r.id)
                        from public.verkoop_regels r left join public.producten p on p.id = r.product_id
                        where r.verkoop_id = v.id), '[]'),
    'betalingen', coalesce((select jsonb_agg(jsonb_build_object('methode', b.methode, 'bedrag_cent', b.bedrag_cent,
                              'kaart_nummer', k.nummer, 'kaart_saldo_na', b.kaart_saldo_na,
                              'gegeven_cent', b.gegeven_cent, 'wisselgeld_cent', b.wisselgeld_cent,
                              'lid_naam', l.naam,
                              'reden', b.reden, 'op_kaart_nummer', ok.nummer, 'op_kaart_cent', b.op_kaart_cent, 'op_kaart_saldo_na', b.op_kaart_saldo_na) order by b.id)
                            from public.betalingen b left join public.kaarten k on k.id = b.kaart_id
                            left join public.leden l on l.id = b.lid_id
                            left join public.kaarten ok on ok.id = b.op_kaart_id
                            where b.verkoop_id = v.id), '[]'))
  from public.verkopen v where v.id = p_verkoop_id
$$;

create function public.bon_bekijken(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  z text := lower(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_id bigint;
begin
  if public._code_geblokkeerd() then
    return jsonb_build_object('fout', 'Te veel verkeerde codes geprobeerd. Probeer het over 10 minuten opnieuw.');
  end if;
  if length(z) <> 24 then return jsonb_build_object('fout', 'Deze link naar een bon klopt niet.'); end if;
  select id into v_id from public.verkopen where deel_code = z;
  if not found then
    perform public._mislukt('code', public._klant_ip());
    return jsonb_build_object('fout', 'Deze bon is niet gevonden. Scan de QR-code opnieuw.');
  end if;
  if (select ts from public.verkopen where id = v_id) < now() - interval '90 days' then
    return jsonb_build_object('fout', 'Deze bon is ouder dan 90 dagen en niet meer te bekijken.');
  end if;
  return public.bon(v_id) - 'id' - 'deel_code';
end $$;
revoke execute on function public.bon_bekijken(text) from public;
grant execute on function public.bon_bekijken(text) to anon, authenticated;
