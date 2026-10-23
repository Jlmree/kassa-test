-- Klanten bekijken zelf het saldo van hun tegoedkaart, zonder in te loggen:
-- ze scannen de QR-code van de kaart met hun eigen telefoon. Alleen met de
-- geheime kaartcode (niet met het kaartnummer), en er kan niets mee veranderd worden.
create function public.kaart_saldo(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  z text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  k public.kaarten;
begin
  if length(z) <> 8 then raise exception 'Typ de code van je kaart (8 tekens, bijvoorbeeld ABCD-EFGH)'; end if;
  select * into k from public.kaarten where replace(code, '-', '') = z;
  if not found then raise exception 'Deze kaart is niet gevonden. Klopt de code?'; end if;
  return jsonb_build_object(
    'nummer', k.nummer, 'naam', k.naam, 'saldo_cent', k.saldo_cent, 'geblokkeerd', k.geblokkeerd,
    'winkel', (select naam from public.instellingen where id = 1),
    'historie', coalesce((
      select jsonb_agg(x order by x.ts desc) from (
        select m.ts, m.bedrag_cent, m.soort from public.kaart_mutaties m
        where m.kaart_id = k.id order by m.ts desc limit 10) x), '[]'));
end $$;
grant execute on function public.kaart_saldo(text) to anon, authenticated;
