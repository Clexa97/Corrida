-- Espectadores com codinome/foto e sem promoção automática para corredor.

alter table public.players
  add column if not exists spectator_only boolean not null default false;

create or replace function public.set_new_player_spectator()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_status public.room_status;
begin
  select status into v_status from public.rooms where id = new.room_id;
  new.is_spectator := new.spectator_only or v_status <> 'lobby';
  return new;
end;
$$;

create or replace function public.start_race(p_room_code text)
returns public.rooms
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_first_player uuid;
begin
  select * into v_room
  from public.rooms
  where code = upper(p_room_code)
  for update;

  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  if v_room.owner_id <> auth.uid() then raise exception 'Somente o dono pode iniciar'; end if;

  if (
    select count(*) from public.players
    where room_id = v_room.id and spectator_only = false
  ) < 2 then
    raise exception 'São necessários pelo menos dois corredores';
  end if;

  update public.players
  set score = 0,
      roll_count = 0,
      finish_position = null,
      finished_at = null,
      is_spectator = spectator_only
  where room_id = v_room.id;

  delete from public.claimed_gifts where room_id = v_room.id;

  select id into v_first_player
  from public.players
  where room_id = v_room.id and spectator_only = false
  order by joined_at, id
  limit 1;

  update public.rooms
  set status = 'racing',
      current_player_id = v_first_player,
      pending_item = null,
      last_event = null,
      winner_id = null,
      owner_present = true
  where id = v_room.id
  returning * into v_room;

  return v_room;
end;
$$;

revoke all on function public.start_race(text) from public, anon;
grant execute on function public.start_race(text) to authenticated;

create or replace function public.leave_room(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_new_owner uuid;
begin
  select * into v_room
  from public.rooms
  where code = upper(p_room_code)
  for update;

  if v_room.id is null then return false; end if;

  delete from public.room_presence
  where room_id = v_room.id and user_id = auth.uid();

  delete from public.players
  where room_id = v_room.id and owner_id = auth.uid();

  if v_room.owner_id = auth.uid() then
    select player.owner_id into v_new_owner
    from public.players player
    join public.room_presence presence
      on presence.room_id = player.room_id
      and presence.user_id = player.owner_id
      and presence.last_seen_at >= now() - interval '2 minutes'
    where player.room_id = v_room.id
    order by player.joined_at, player.id
    limit 1;

    if v_new_owner is null then
      select user_id into v_new_owner
      from public.room_presence
      where room_id = v_room.id
        and last_seen_at >= now() - interval '2 minutes'
      order by last_seen_at
      limit 1;
    end if;

    if v_new_owner is null then
      delete from public.rooms where id = v_room.id;
      return true;
    end if;

    update public.rooms
    set owner_id = v_new_owner,
        owner_present = true
    where id = v_room.id;
  elsif not exists (
    select 1 from public.room_presence
    where room_id = v_room.id
      and last_seen_at >= now() - interval '2 minutes'
  ) then
    delete from public.rooms where id = v_room.id;
  end if;

  return true;
end;
$$;

revoke all on function public.leave_room(text) from public, anon;
grant execute on function public.leave_room(text) to authenticated;

create or replace function public.next_player_id(p_room_id uuid, p_current_id uuid)
returns uuid language sql stable set search_path = '' as $$
  with ordered as (
    select id, row_number() over (order by joined_at, id) as position
    from public.players
    where room_id = p_room_id
      and finish_position is null
      and is_spectator = false
      and spectator_only = false
  ), current_position as (
    select position from ordered where id = p_current_id
  )
  select coalesce(
    (select id from ordered
      where position > coalesce((select position from current_position), 0)
      order by position limit 1),
    (select id from ordered order by position limit 1)
  );
$$;
