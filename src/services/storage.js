import { supabase } from "../lib/supabase.js";

export async function uploadAvatar({ userId, playerId, dataUrl }) {
  if (!dataUrl || dataUrl.startsWith("data:image/svg+xml")) return dataUrl;
  const blob = await (await fetch(dataUrl)).blob();
  const path = `${userId}/${playerId}.jpg`;
  const { error } = await supabase.storage.from("avatars").upload(path, blob, {
    contentType: "image/jpeg",
    upsert: true
  });
  if (error) throw error;
  return supabase.storage.from("avatars").getPublicUrl(path).data.publicUrl;
}
