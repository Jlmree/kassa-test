-- Wat er nieuw is in de nieuwste versie: bijwerker.sh haalt het lijstje
-- (wijzigingen.json uit de GitHub-release) op, zodat een beheerder vóór het
-- bijwerken ziet wat de update brengt.
alter table public.systeem add column wijzigingen jsonb;
