import { supabase } from "../lib/supabase.js";

const roomSelect = "*, players!players_room_id_fkey(*), claimed_gifts(*)";

export async function listRooms() {
  await supabase.rpc("cleanup_abandoned_rooms");
  const { data, error } = await supabase
    .from("rooms")
    .select(roomSelect)
    .order("created_at", { ascending: false })
    .limit(30);
  if (error) throw error;
  return data;
}

export async function findRoom(code) {
  const { data, error } = await supabase
    .from("rooms")
    .select(roomSelect)
    .eq("code", code.toUpperCase())
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function createRoom({ name, laps, maxPlayersPerUser = 1 }) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const bytes = crypto.getRandomValues(new Uint8Array(6));
    const code = Array.from(bytes, value => alphabet[value % alphabet.length]).join("");
    const { data, error } = await supabase
      .from("rooms")
      .insert({ code, name, laps, max_players_per_user: maxPlayersPerUser })
      .select(roomSelect)
      .single();
    if (!error) return data;
    if (error.code !== "23505") throw error;
  }
  throw new Error("Não foi possível gerar um código único para a sala.");
}

export async function addPlayer({ id, roomId, codename, avatarUrl, spectatorOnly = false }) {
  const { data, error } = await supabase
    .from("players")
    .insert({
      id,
      room_id: roomId,
      codename,
      avatar_url: avatarUrl,
      spectator_only: spectatorOnly
    })
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function removePlayer(playerId) {
  const { error } = await supabase.from("players").delete().eq("id", playerId);
  if (error) throw error;
}

export async function deleteRoom(roomId) {
  const { error } = await supabase.from("rooms").delete().eq("id", roomId);
  if (error) throw error;
}

export async function startRace(roomCode) {
  const { data, error } = await supabase.rpc("start_race", { p_room_code: roomCode });
  if (error) throw error;
  return data;
}

export async function rollD20(roomCode) {
  const { data, error } = await supabase.rpc("roll_d20", { p_room_code: roomCode });
  if (error) throw error;
  return data;
}

export async function useItem(roomCode, targetPlayerId) {
  const { data, error } = await supabase.rpc("use_pending_item", {
    p_room_code: roomCode,
    p_target_player_id: targetPlayerId
  });
  if (error) throw error;
  return data;
}

export async function expirePendingItem(roomCode) {
  const { data, error } = await supabase.rpc("expire_pending_item", {
    p_room_code: roomCode
  });
  if (error) throw error;
  return data;
}

export async function leaveRoom(roomCode) {
  const { data, error } = await supabase.rpc("leave_room", { p_room_code: roomCode });
  if (error) throw error;
  return data;
}

export async function enterRoom(roomCode, spectatorOnly = false) {
  const { data, error } = await supabase.rpc("enter_room", {
    p_room_code: roomCode,
    p_spectator_only: spectatorOnly
  });
  if (error) throw error;
  return data;
}

export async function heartbeatRoom(roomCode) {
  const { data, error } = await supabase.rpc("heartbeat_and_cleanup", {
    p_room_code: roomCode
  });
  if (error) throw error;
  return data;
}

export async function sendChatMessage(roomCode, playerId, message, emote) {
  const { data, error } = await supabase.rpc("send_chat_message", { p_room_code: roomCode, p_player_id: playerId, p_message: message, p_emote: emote });
  if (error) throw error;
  return data;
}

export async function listActiveChat(roomId) {
  const { data, error } = await supabase.from("chat_messages").select("*").eq("room_id", roomId).gt("expires_at", new Date().toISOString()).order("created_at");
  if (error) throw error;
  return data;
}

export function subscribeToRoom(roomId, onChange) {
  const channel = supabase
    .channel(`room:${roomId}`)
    .on("postgres_changes", { event: "*", schema: "public", table: "rooms", filter: `id=eq.${roomId}` }, onChange)
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "chat_messages", filter: `room_id=eq.${roomId}` }, onChange)
    .subscribe();
  return () => supabase.removeChannel(channel);
}
