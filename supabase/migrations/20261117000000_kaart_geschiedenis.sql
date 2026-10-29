-- Saldo-pagina: de geschiedenis van de kaart met wat er gekocht is. Bij elke betaling met de
-- kaart staat wat er op de bon stond (bijv. 2× Bier, 1× Chips), en tot 90 dagen terug de
-- geheime code van die bon, zodat de klant de hele bon kan openen (zie bon_bekijken). Wie de
-- kaartcode heeft, mag dit zien: het is zijn eigen kaart. De laatste 50 keer (was 10).

create or replace function public.kaart_saldo(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  z text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  k public.kaarten;
begin
  if public._code_geblokkeerd() then
    return jsonb_build_object('fout', 'Te veel verkeerde codes geprobeerd. Probeer het over 10 minuten opnieuw.');
  end if;
  if length(z) <> 8 then return jsonb_build_object('fout', 'Typ de code van je kaart (8 tekens, bijvoorbeeld ABCD-EFGH)'); end if;
  select * into k from public.kaarten where replace(code, '-', '') = z;
  if not found then
    perform public._mislukt('code', public._klant_ip());
    return jsonb_build_object('fout', 'Deze kaart is niet gevonden. Klopt de code?');
  end if;
  if k.verwijderd_ts is not null then return jsonb_build_object('fout', 'Deze kaart is niet meer in gebruik.'); end if;
  return jsonb_build_object(
    'nummer', k.nummer, 'naam', k.naam, 'saldo_cent', k.saldo_cent, 'geblokkeerd', k.geblokkeerd,
    'winkel', (select naam from public.instellingen where id = 1),
    'historie', coalesce((
      select jsonb_agg(x order by x.ts desc) from (
        select m.ts, m.bedrag_cent, m.soort, m.methode, v.bonnummer as bon,
               (select string_agg(r.aantal || '× ' || r.naam, ', ' order by r.id) from public.verkoop_regels r where r.verkoop_id = v.id) as wat,
               case when v.ts >= now() - interval '90 days' then v.deel_code end as bon_code
        from public.kaart_mutaties m left join public.verkopen v on v.id = m.verkoop_id
        where m.kaart_id = k.id order by m.ts desc limit 50) x), '[]'));
end $$;
