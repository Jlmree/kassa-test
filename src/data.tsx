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

  const herlaad = useCallback(async () => {
    // Lopende lading? Dan daarna nog één keer, zodat niets gemist wordt.
    if (bezig.current) { opnieuw.current = true; return bezig.current; }
    bezig.current = (async () => {
      try {
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
    // Live bijwerken als een ander apparaat iets verandert.
    let t = 0;
    const later = () => { clearTimeout(t); t = window.setTimeout(() => void herlaad(), 250); };
    const kanaal = sb.channel('kassa')
      .on('postgres_changes', { event: '*', schema: 'public' }, later)
      .subscribe();
    const zicht = () => document.visibilityState === 'visible' && later();
    document.addEventListener('visibilitychange', zicht);
    addEventListener('online', later);
    const iv = setInterval(later, 60_000);
    return () => {
      void sb.removeChannel(kanaal);
      document.removeEventListener('visibilitychange', zicht);
      removeEventListener('online', later);
      clearInterval(iv);
      clearTimeout(t);
    };
  }, [herlaad]);

  return <Ctx.Provider value={{ ...s, profiel, herlaad }}>{children}</Ctx.Provider>;
}
