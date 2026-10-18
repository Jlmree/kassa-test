import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { lees, rpc, sb, type Dienst, type Product, type Profiel, type Rekening, type RekeningRegel } from './lib';

interface Data {
  profiel: Profiel;
  producten: Product[];
  rekeningen: Rekening[];
  regels: RekeningRegel[];
  dienst: Dienst | null;
  winkel: string;
  geladen: boolean;
  verbonden: boolean;
  herlaad: () => Promise<void>;
}

const Ctx = createContext<Data>(null!);
export const useData = () => useContext(Ctx);

export function DataProvider({ profiel, children }: { profiel: Profiel; children: ReactNode }) {
  const [s, setS] = useState<Omit<Data, 'herlaad' | 'profiel'>>({
    producten: [], rekeningen: [], regels: [], dienst: null, winkel: 'Bar', geladen: false, verbonden: true,
  });
  const bezig = useRef<Promise<void> | null>(null);
  const opnieuw = useRef(false);
  // Stand van de wijzigingsteller bij de laatste lading.
  const versie = useRef<number | null>(null);

  const herlaad = useCallback(async () => {
    // Lopende lading? Dan daarna nog één keer, zodat niets gemist wordt.
    if (bezig.current) { opnieuw.current = true; return bezig.current; }
    bezig.current = (async () => {
      try {
        // Eerst de teller, dan de gegevens: zo wordt een wijziging tijdens het laden nooit gemist.
        const v = await rpc<number>('versie');
        const [producten, rekeningen, regels, dienst, inst] = await Promise.all([
          lees(sb.from('producten').select('*').eq('verwijderd', false).order('categorie').order('volgorde').order('naam')),
          lees(sb.from('rekeningen').select('*').eq('open', true).order('naam')),
          lees(sb.from('rekening_regels').select('*, rekeningen!inner(open)').eq('rekeningen.open', true).order('id')),
          rpc<Dienst | null>('dienst_overzicht'),
          lees(sb.from('instellingen').select('naam').maybeSingle()),
        ]);
        setS({
          producten: producten as Product[], rekeningen: rekeningen as Rekening[], regels: regels as RekeningRegel[],
          dienst, winkel: (inst as { naam: string } | null)?.naam ?? 'Bar', geladen: true, verbonden: true,
        });
        versie.current = v;
      } catch {
        setS((x) => ({ ...x, geladen: true, verbonden: false }));
      } finally {
        bezig.current = null;
        if (opnieuw.current) { opnieuw.current = false; void herlaad(); }
      }
    })();
    return bezig.current;
  }, []);

  useEffect(() => {
    void herlaad();
    // Elke paar seconden de wijzigingsteller opvragen; alleen bij een
    // verandering (ook door een ander apparaat) alles opnieuw laden.
    let t = 0, stop = false;
    const kijk = async () => {
      if (document.visibilityState === 'visible') {
        try {
          if ((await rpc<number>('versie')) !== versie.current) await herlaad();
          else setS((x) => (x.verbonden ? x : { ...x, verbonden: true }));
        } catch {
          setS((x) => ({ ...x, verbonden: false }));
        }
      }
      if (!stop) t = window.setTimeout(kijk, 3000);
    };
    t = window.setTimeout(kijk, 3000);
    const zicht = () => { if (document.visibilityState === 'visible') void herlaad(); };
    document.addEventListener('visibilitychange', zicht);
    return () => { stop = true; clearTimeout(t); document.removeEventListener('visibilitychange', zicht); };
  }, [herlaad]);

  return <Ctx.Provider value={{ ...s, profiel, herlaad }}>{children}</Ctx.Provider>;
}
