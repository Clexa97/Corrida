-- Registra o resultado do presente para animação sincronizada em todas as telas.

alter table public.rooms add column if not exists last_event jsonb;

create or replace function public.clear_room_event_on_race_start()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'racing' and old.status is distinct from new.status then
    new.last_event = null;
  end if;
  return new;
end;
$$;

drop trigger if exists rooms_clear_event_on_race_start on public.rooms;
create trigger rooms_clear_event_on_race_start
before update of status on public.rooms
for each row execute function public.clear_room_event_on_race_start();

create or replace function public.use_pending_item(p_room_code text, p_target_player_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_source public.players;
  v_target public.players;
  v_damage integer;
  v_event jsonb;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.pending_item is null then raise exception 'Não há item pendente'; end if;
  select * into v_source from public.players where id = (v_room.pending_item->>'player_id')::uuid;
  if now() >= (v_room.pending_item->>'expires_at')::timestamptz then
    update public.rooms set pending_item = null,
      current_player_id = public.next_player_id(v_room.id, v_source.id) where id = v_room.id;
    return jsonb_build_object('expired', true);
  end if;
  if auth.uid() not in (v_source.owner_id, v_room.owner_id) then raise exception 'Sem permissão para usar este item'; end if;
  select * into v_target from public.players where id = p_target_player_id and room_id = v_room.id for update;
  if v_target.id is null or v_target.id = v_source.id then raise exception 'Alvo inválido'; end if;
  v_damage := (v_room.pending_item->>'damage')::integer;
  v_event := jsonb_build_object('id', gen_random_uuid(), 'type', v_room.pending_item->>'type',
    'source_id', v_source.id, 'target_id', v_target.id, 'damage', v_damage, 'created_at', now());
  update public.players set score = greatest(0, score - v_damage) where id = v_target.id;
  update public.rooms set pending_item = null,
    current_player_id = public.next_player_id(v_room.id, v_source.id), last_event = v_event
    where id = v_room.id;
  return jsonb_build_object('target_id', v_target.id, 'damage', v_damage, 'event', v_event);
end;
$$;
