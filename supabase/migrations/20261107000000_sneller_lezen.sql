-- Sneller lezen als er veel telefoons tegelijk verversen.
--
-- De toegangsregels (wie mag wat zien) riepen is_medewerker() en is_beheerder()
-- voor elke rij opnieuw aan. Tussen haakjes met select rekent de database het
-- één keer per opvraging uit. Wie wat mag zien, verandert niet.

alter policy lezen on public.diensten        using ((select public.is_medewerker()));
alter policy lezen on public.instellingen    using ((select public.is_medewerker()));
alter policy lezen on public.kaart_mutaties  using ((select public.is_beheerder()));
alter policy lezen on public.kaarten         using ((select public.is_medewerker()));
alter policy lezen on public.lat_betalingen  using ((select public.is_medewerker()));
alter policy lezen on public.leden           using ((select public.is_medewerker()));
alter policy lezen on public.logboek         using ((select public.is_beheerder()));
alter policy lezen on public.producten       using ((select public.is_medewerker()));
alter policy lezen on public.profielen       using (id = (select auth.uid()) or (select public.is_medewerker()));
alter policy lezen on public.rekening_regels using ((select public.is_medewerker()));
alter policy lezen on public.rekeningen      using ((select public.is_medewerker()));
alter policy lezen on public.systeem         using ((select public.is_beheerder()));
alter policy lezen on public.uitgaven        using ((select public.mijn_rol()) in ('medewerker', 'beheerder'));
alter policy lezen on public.uitnodigingen   using ((select public.is_beheerder()));
alter policy lezen on public.verkopen        using ((select public.is_beheerder()) or ((select public.is_medewerker()) and ts > now() - interval '24 hours'));
alter policy lezen on public.voorraad_mutaties using ((select public.is_beheerder()));
