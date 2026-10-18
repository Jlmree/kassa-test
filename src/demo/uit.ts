// Gewone kassa (geen proefversie): niets van de proefdatabase meenemen.
// vite.config.ts kiest tussen dit bestand en client.ts.
import type { SupabaseClient } from '@supabase/supabase-js';

export const proefClient = null as unknown as SupabaseClient;
export const proefLaden = async () => {};
export const proefOpnieuw = async () => {};
