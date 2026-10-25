// Aanvraagformulier: verstuurt naar /aanvraag op deze server (website-aanvraag.py), die het doormailt.
(() => {
  const form = document.getElementById('formulier');
  const melding = document.getElementById('f-melding');
  const knop = document.getElementById('f-verstuur');
  const geopend = Date.now();

  // "Aanvragen" onder een prijs zet die keuze alvast aan.
  document.querySelectorAll('[data-keus]').forEach((a) => a.addEventListener('click', () => {
    const r = document.getElementById(a.dataset.keus === 'server' ? 'f-server' : 'f-kastje');
    if (r) r.checked = true;
  }));

  const toon = (tekst, goed) => {
    melding.textContent = tekst;
    melding.className = 'heel melding ' + (goed ? 'goed' : 'fout');
  };

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const d = Object.fromEntries(new FormData(form));
    if (!String(d.naam || '').trim() || !String(d.club || '').trim()) return toon('Vul je naam en de naam van de vereniging of kantine in.', false);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(d.email || '').trim())) return toon('Vul een geldig e-mailadres in, zodat we je kunnen antwoorden.', false);
    d.seconden = Math.round((Date.now() - geopend) / 1000);
    knop.disabled = true;
    knop.textContent = 'Versturen…';
    try {
      const r = await fetch('aanvraag', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(d) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.fout || 'Versturen lukte niet.');
      form.reset();
      toon('Bedankt! Je aanvraag is binnen. We nemen zo snel mogelijk contact met je op.', true);
    } catch (err) {
      toon((err instanceof TypeError ? 'Geen verbinding met de server.' : err.message) + ' Probeer het later nog eens, of mail ons.', false);
    } finally {
      knop.disabled = false;
      knop.textContent = 'Aanvraag versturen';
    }
  });
})();
