-- Back-up per e-mail: elke nacht gaat de versleutelde back-up naar een e-mailadres
-- (backup-mail.sh). Zo staat er altijd een kopie buiten de server. De beheerder ziet
-- in de app of het lukt (Beheer → Instellingen → Back-up).

alter table public.systeem
  add column backup_mail_naar text,          -- naar welk adres (leeg: staat uit)
  add column backup_mail_ts   timestamptz,   -- laatst gelukt
  add column backup_mail_fout text;          -- waarom het de laatste keer mislukte (leeg: gelukt)
