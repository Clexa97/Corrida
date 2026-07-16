import { isSupabaseConfigured, supabase } from "../lib/supabase.js";

export async function ensureGuestSession() {
  if (!isSupabaseConfigured) return null;
  const { data: sessionData } = await supabase.auth.getSession();
  if (sessionData.session) return sessionData.session.user;
  const { data, error } = await supabase.auth.signInAnonymously();
  if (error) throw error;
  return data.user;
}
