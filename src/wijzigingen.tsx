import { useEffect } from 'react';
import lijst from './wijzigingen.json';
import { datum } from './lib';
import { useSheet } from './ui';

// Wat er per versie anders is, nieuwste eerst. Nieuwe punten bovenaan in
// wijzigingen.json zetten; dezelfde lijst gaat mee in de GitHub-release.
export interface Wijziging { datum: string; titel: string; punten: string[] }
export const wijzigingen: Wijziging[] = lijst;
const sleutel = (w: Wijziging) => `${w.datum} ${w.titel}`;

// Wat in `nieuw` staat en nog niet in `bekend`.
export function nieuwer(nieuw: Wijziging[], bekend: Wijziging[]) {
  const k = new Set(bekend.map(sleutel));
  return nieuw.filter((w) => !k.has(sleutel(w)));
}

export function WijzigingLijst({ lijst }: { lijst: Wijziging[] }) {
  return (
    <>
      {lijst.map((w) => (
        <div className="wijziging" key={sleutel(w)}>
          <b>{w.titel}</b> <span className="mu">{datum(w.datum)}</span>
          <ul>{w.punten.map((p) => <li key={p}>{p}</li>)}</ul>
        </div>
      ))}
    </>
  );
}

// Na een update één keer laten zien wat er nieuw is (per apparaat).
const GEZIEN = 'kassa-wijzigingen-gezien';
export function NieuwNaUpdate() {
  const { open, sluit } = useSheet();
  useEffect(() => {
    const nu = sleutel(wijzigingen[0]);
    let gezien: string | null;
    try {
      gezien = localStorage.getItem(GEZIEN);
      localStorage.setItem(GEZIEN, nu);
    } catch { return; }
    // Eerste keer op dit apparaat, of niets nieuws: niets tonen.
    if (!gezien || gezien === nu) return;
    const i = wijzigingen.findIndex((w) => sleutel(w) === gezien);
    open(
      <>
        <h2>Nieuw in deze versie</h2>
        <WijzigingLijst lijst={wijzigingen.slice(0, i === -1 ? 1 : i)} />
        <button className="big" onClick={sluit}>Begrepen</button>
      </>,
    );
  }, [open, sluit]);
  return null;
}
