-- Kassa leegmaken (Beheer → Instellingen → Kassa leegmaken): terug naar het begin, zonder
-- producten, kaarten, verkopen, diensten, rekeningen, streeplijst, uitgaven en loterij.
-- Bonnummers en kaartnummers beginnen weer bij 1. Alleen een beheerder, en alleen met het
-- woord LEEGMAKEN als bevestiging.
--
-- Wat blijft: de accounts (de beheerder die leegmaakt zeker), het logboek (met een regel dat
-- de kassa is leeggemaakt en hoeveel er weg ging, zodat leegmaken nooit ongezien kan) en de
-- back-ups op de server. Optioneel: andere medewerkers uitschakelen, en de instellingen
-- (naam, betaalmethoden, thema, btw) terug naar standaard. Zelf aanmelden blijft zoals het
-- staat: op een kassa op internet mag dat niet ongemerkt weer aan gaan.

create function public.kassa_leegmaken(p_bevestiging text, p_medewerkers boolean default false, p_instellingen boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare res jsonb;
begin
  perform public._eis('beheerder');
  if coalesce(p_bevestiging, '') <> 'LEEGMAKEN' then raise exception 'Typ LEEGMAKEN om te bevestigen'; end if;

  res := jsonb_build_object(
    'producten', (select count(*) from public.producten where not verwijderd),
    'kaarten', (select count(*) from public.kaarten),
    'tegoed_cent', (select coalesce(sum(saldo_cent), 0) from public.kaarten),
    'bonnen', (select count(*) from public.verkopen),
    'diensten', (select count(*) from public.diensten),
    'leden', (select count(*) from public.leden),
    'rekeningen', (select count(*) from public.rekeningen),
    'uitgaven', (select count(*) from public.uitgaven),
    'medewerkers_uit', case when p_medewerkers then (select count(*) from public.profielen where actief and id <> auth.uid()) else 0 end,
    'instellingen', coalesce(p_instellingen, false));

  -- Zonder cascade: verwijst een tabel die moet blijven toch naar een van deze, dan stopt het hier.
  truncate public.betalingen, public.verkoop_regels, public.kaart_mutaties, public.voorraad_mutaties,
    public.lat_betalingen, public.loterij_trekkingen, public.rekening_regels, public.uitgaven,
    public.verkopen, public.rekeningen, public.diensten, public.kaarten, public.leden, public.producten,
    public.uitnodigingen restart identity;
  alter sequence public.bon_nummer restart;
  alter sequence public.kaart_nummer restart;

  if p_medewerkers then
    update public.profielen set actief = false where id <> auth.uid() and actief;
  end if;
  if p_instellingen then
    update public.instellingen set naam = default, betaal_contant = default, betaal_pin = default, betaal_kaart = default,
      betaal_rekening = default, betaal_lat = default, betaal_gratis = default, thema = default, btw_aan = default, btw_nummer = default;
  end if;

  perform public._log('kassa_leegmaken', res);
  -- Alle telefoons laden opnieuw.
  perform nextval('public.wijziging');
  return res;
end $$;
revoke execute on function public.kassa_leegmaken(text, boolean, boolean) from public, anon;
grant execute on function public.kassa_leegmaken(text, boolean, boolean) to authenticated;
