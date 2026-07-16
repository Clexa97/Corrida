create extension if not exists pgcrypto;

create type public.room_status as enum ('lobby', 'racing', 'finished');

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  name text not null check (char_length(name) between 1 and 36),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  laps smallint not null check (laps between 1 and 12),
  status public.room_status not null default 'lobby',
  current_player_id uuid,
  pending_item jsonb,
  last_event jsonb,
  winner_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  codename text not null check (char_length(codename) between 1 and 16),
  avatar_url text,
  score integer not null default 0 check (score >= 0),
  roll_count integer not null default 0 check (roll_count >= 0),
  joined_at timestamptz not null default now(),
  unique (room_id, owner_id),
  unique (room_id, codename)
);

alter table public.rooms
  add constraint rooms_current_player_fk foreign key (current_player_id) references public.players(id) on delete set null,
  add constraint rooms_winner_fk foreign key (winner_id) references public.players(id) on delete set null;

create table public.claimed_gifts (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  lap smallint not null check (lap between 1 and 12),
  marker smallint not null check (marker in (25, 50, 75)),
  item_type text not null,
  created_at timestamptz not null default now(),
  unique (player_id, lap, marker)
);

create index players_room_id_idx on public.players(room_id);
create index claimed_gifts_room_id_idx on public.claimed_gifts(room_id);

alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.claimed_gifts enable row level security;

create policy "authenticated users can view rooms"
on public.rooms for select to authenticated using (true);

create policy "authenticated users can create rooms"
on public.rooms for insert to authenticated
with check ((select auth.uid()) = owner_id);

create policy "room owner can delete room"
on public.rooms for delete to authenticated
using ((select auth.uid()) = owner_id);

create policy "authenticated users can view players"
on public.players for select to authenticated using (true);

create policy "users can create their own player"
on public.players for insert to authenticated
with check (
  (select auth.uid()) = owner_id
  and exists (
    select 1 from public.rooms r
    where r.id = room_id and r.status = 'lobby'
  )
);

create policy "player owner or room owner can delete player"
on public.players for delete to authenticated
using (
  (select auth.uid()) = owner_id
  or exists (
    select 1 from public.rooms r
    where r.id = room_id and r.owner_id = (select auth.uid())
  )
);

create policy "authenticated users can view claimed gifts"
on public.claimed_gifts for select to authenticated using (true);

-- Não há políticas públicas de UPDATE para players nem INSERT em claimed_gifts.
-- Pontos, turnos e itens só podem mudar pelas funções SECURITY DEFINER abaixo.

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger rooms_touch_updated_at
before update on public.rooms
for each row execute function public.touch_updated_at();

create or replace function public.next_player_id(p_room_id uuid, p_current_id uuid)
returns uuid language sql stable set search_path = '' as $$
  with ordered as (
    select id, row_number() over (order by joined_at, id) as position
    from public.players where room_id = p_room_id
  ), current_position as (
    select position from ordered where id = p_current_id
  )
  select coalesce(
    (select id from ordered where position > (select position from current_position) order by position limit 1),
    (select id from ordered order by position limit 1)
  );
$$;

create or replace function public.start_race(p_room_code text)
returns public.rooms
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_first_player uuid;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  if v_room.owner_id <> auth.uid() then raise exception 'Somente o dono pode iniciar'; end if;
  if (select count(*) from public.players where room_id = v_room.id) < 2 then
    raise exception 'São necessários pelo menos dois pilotos';
  end if;

  update public.players set score = 0, roll_count = 0 where room_id = v_room.id;
  delete from public.claimed_gifts where room_id = v_room.id;
  select id into v_first_player from public.players where room_id = v_room.id order by joined_at, id limit 1;
  update public.rooms set status = 'racing', current_player_id = v_first_player,
    pending_item = null, last_event = null, winner_id = null where id = v_room.id returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.roll_d20(p_room_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
  v_roll integer := floor(random() * 20 + 1);
  v_old_score integer;
  v_new_score integer;
  v_total integer;
  v_lap integer;
  v_marker integer;
  v_absolute integer;
  v_item text;
  v_damage integer;
  v_pending jsonb := null;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.status <> 'racing' then raise exception 'A corrida não está ativa'; end if;
  if v_room.pending_item is not null then raise exception 'Resolva o item pendente primeiro'; end if;
  select * into v_player from public.players where id = v_room.current_player_id for update;
  if auth.uid() not in (v_player.owner_id, v_room.owner_id) then raise exception 'Não é a sua vez'; end if;

  v_old_score := v_player.score;
  v_new_score := v_old_score + v_roll;
  v_total := v_room.laps * 100;
  update public.players set score = v_new_score, roll_count = roll_count + 1 where id = v_player.id;

  if v_new_score >= v_total then
    update public.rooms set status = 'finished', winner_id = v_player.id where id = v_room.id;
    return jsonb_build_object('roll', v_roll, 'winner_id', v_player.id);
  end if;

  for v_lap in 1..v_room.laps loop
    foreach v_marker in array array[25, 50, 75] loop
      v_absolute := (v_lap - 1) * 100 + v_marker;
      if v_old_score < v_absolute and v_new_score >= v_absolute and not exists (
        select 1 from public.claimed_gifts
        where player_id = v_player.id and lap = v_lap and marker = v_marker
      ) then
        case floor(random() * 4)::integer
          when 0 then v_item := 'shell'; v_damage := 15;
          when 1 then v_item := 'banana'; v_damage := 8;
          when 2 then v_item := 'lightning'; v_damage := 20;
          else v_item := 'turbo'; v_damage := 0;
        end case;
        insert into public.claimed_gifts(room_id, player_id, lap, marker, item_type)
          values(v_room.id, v_player.id, v_lap, v_marker, v_item);
        if v_item = 'turbo' then
          v_new_score := v_new_score + 15;
          update public.players set score = v_new_score where id = v_player.id;
        else
          v_pending := jsonb_build_object('player_id', v_player.id, 'type', v_item,
            'damage', v_damage, 'lap', v_lap, 'marker', v_marker,
            'expires_at', now() + interval '1 minute');
        end if;
        exit;
      end if;
    end loop;
    exit when v_pending is not null or v_item = 'turbo';
  end loop;

  if v_new_score >= v_total then
    update public.rooms set status = 'finished', winner_id = v_player.id where id = v_room.id;
  elsif v_pending is not null then
    update public.rooms set pending_item = v_pending where id = v_room.id;
  else
    update public.rooms set current_player_id = public.next_player_id(v_room.id, v_player.id) where id = v_room.id;
  end if;

  return jsonb_build_object('roll', v_roll, 'item', v_item, 'pending_item', v_pending,
    'player_id', v_player.id, 'score', v_new_score);
end;
$$;

create or replace function public.use_pending_item(p_room_code text, p_target_player_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_source public.players;
  v_target public.players;
  v_damage integer;
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
  update public.players set score = greatest(0, score - v_damage) where id = v_target.id;
  update public.rooms set pending_item = null,
    current_player_id = public.next_player_id(v_room.id, v_source.id),
    last_event = jsonb_build_object('id', gen_random_uuid(), 'type', v_room.pending_item->>'type',
      'source_id', v_source.id, 'target_id', v_target.id, 'damage', v_damage, 'created_at', now())
    where id = v_room.id;
  return jsonb_build_object('target_id', v_target.id, 'damage', v_damage);
end;
$$;

create or replace function public.expire_pending_item(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_source_id uuid;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null or v_room.pending_item is null then return false; end if;
  if now() < (v_room.pending_item->>'expires_at')::timestamptz then return false; end if;
  v_source_id := (v_room.pending_item->>'player_id')::uuid;
  update public.rooms set pending_item = null,
    current_player_id = public.next_player_id(v_room.id, v_source_id) where id = v_room.id;
  return true;
end;
$$;

revoke all on function public.start_race(text) from public, anon;
revoke all on function public.roll_d20(text) from public, anon;
revoke all on function public.use_pending_item(text, uuid) from public, anon;
revoke all on function public.expire_pending_item(text) from public, anon;
grant execute on function public.start_race(text) to authenticated;
grant execute on function public.roll_d20(text) to authenticated;
grant execute on function public.use_pending_item(text, uuid) to authenticated;
grant execute on function public.expire_pending_item(text) to authenticated;

create or replace function public.delete_empty_room_after_player_leave()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.players where room_id = old.room_id) then
    delete from public.rooms where id = old.room_id;
  end if;
  return old;
end;
$$;

create trigger players_delete_empty_room
after delete on public.players
for each row execute function public.delete_empty_room_after_player_leave();

create or replace function public.repair_room_after_player_leave()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_next uuid;
begin
  select id into v_next from public.players
    where room_id = old.room_id order by joined_at, id limit 1;
  if v_next is not null then
    update public.rooms
      set current_player_id = coalesce(current_player_id, v_next),
          pending_item = case
            when (pending_item->>'player_id')::uuid = old.id then null
            else pending_item
          end
      where id = old.room_id;
  end if;
  return old;
end;
$$;

create trigger players_repair_room_after_leave
after delete on public.players
for each row execute function public.repair_room_after_player_leave();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "avatar images are public"
on storage.objects for select using (bucket_id = 'avatars');

create policy "users upload avatars to their folder"
on storage.objects for insert to authenticated
with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "users update their avatars"
on storage.objects for update to authenticated
using (bucket_id = 'avatars' and owner_id = (select auth.uid())::text)
with check (bucket_id = 'avatars' and owner_id = (select auth.uid())::text);

create policy "users delete their avatars"
on storage.objects for delete to authenticated
using (bucket_id = 'avatars' and owner_id = (select auth.uid())::text);

alter publication supabase_realtime add table public.rooms;
alter publication supabase_realtime add table public.players;
