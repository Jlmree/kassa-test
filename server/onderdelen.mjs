// Maakt ONDERDELEN.txt: de licenties van de programma's van anderen die in het
// installatiebestand zitten (PostgREST, Supabase Auth en de bibliotheken van de app).
//   node server/onderdelen.mjs <uitvoer> <licentiebestand van een programma>...
// Elk licentiebestand heet <naam> <versie>.txt, bijv. "PostgREST v12.2.3.txt".
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';

const [uit, ...programmas] = process.argv.slice(2);
const streep = '-'.repeat(76);
const delen = [];

for (const f of programmas) delen.push(`${basename(f, '.txt')}\n\n${readFileSync(f, 'utf8').trim()}`);

// Alle pakketten die in de app terechtkomen (zonder hulpmiddelen voor het bouwen).
const boom = JSON.parse(execFileSync('npm', ['ls', '--omit=dev', '--all', '--json'], { encoding: 'utf8' }));
const gezien = new Map();
(function loop(deps) {
  for (const [naam, d] of Object.entries(deps ?? {})) {
    // Optionele pakketten die niet zijn geïnstalleerd, zitten ook niet in de app.
    if (d.missing || !d.version || !existsSync(join('node_modules', naam))) continue;
    if (!gezien.has(naam)) gezien.set(naam, d.version);
    loop(d.dependencies);
  }
})(boom.dependencies);

for (const [naam, versie] of [...gezien].sort(([a], [b]) => a.localeCompare(b))) {
  const map = join('node_modules', naam);
  const pkg = JSON.parse(readFileSync(join(map, 'package.json'), 'utf8'));
  const bestand = readdirSync(map).find((f) => /^(licen[cs]e|copying)/i.test(f));
  const tekst = bestand
    ? readFileSync(join(map, bestand), 'utf8').trim()
    : `Licentie: ${pkg.license ?? 'onbekend'}${pkg.author ? `\nAuteur: ${typeof pkg.author === 'string' ? pkg.author : pkg.author.name}` : ''}${pkg.homepage ? `\n${pkg.homepage}` : ''}`;
  delen.push(`${naam} ${versie}\n\n${tekst}`);
}

writeFileSync(uit, `Bar-kassa: onderdelen van anderen

De Bar-kassa gebruikt de volgende programma's en bibliotheken, elk met een eigen
licentie. PostgreSQL en Caddy worden niet meegeleverd maar tijdens de installatie
uit de pakketbron van Debian of Ubuntu geïnstalleerd, met hun eigen licentie
(PostgreSQL License en Apache License 2.0).

${delen.map((d) => `${streep}\n${d}\n`).join('\n')}`);
