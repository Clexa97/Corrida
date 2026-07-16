-- Permite entrar durante/depois da corrida; novos corredores aguardam a próxima largada.

alter table public.players
  add column if not exists is_spectator boolean not null default false;

create or replace function public.set_new_player_spectator()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_status public.room_status;
begin
  select status into v_status from public.rooms where id = new.room_id;
  new.is_spectator := v_status <> 'lobby';
  return new;
end;
$$;

drop trigger if exists players_set_spectator on public.players;
create trigger players_set_spectator
before insert on public.players
for each row execute function public.set_new_player_spectator();

drop policy if exists "users can create their own player" on public.players;
create policy "users can create their own player"
on public.players for insert to authenticated
with check (
  (select auth.uid()) = owner_id
  and exists (
    select 1 from public.rooms r
    where r.id = room_id
      and (select count(*) from public.players p
        where p.room_id = r.id and p.owner_id = (select auth.uid())) < r.max_players_per_user
  )
);

drop policy if exists "player owner or room owner can delete player" on public.players;
create policy "player owner or room owner can delete player"
on public.players for delete to authenticated using (
  (select auth.uid()) = owner_id
  or exists (
    select 1 from public.rooms r
    where r.id = room_id and r.owner_id = (select auth.uid())
      and (
        players.is_spectator
        or r.status <> 'racing'
        or (
          r.current_player_id = players.id
          and now() >= r.turn_started_at + interval '1 minute'
        )
      )
  )
);

create or replace function public.next_player_id(p_room_id uuid, p_current_id uuid)
returns uuid language sql stable set search_path = '' as $$
  with ordered as (
    select id, row_number() over (order by joined_at, id) as position
    from public.players
    where room_id = p_room_id and finish_position is null and is_spectator = false
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

-- Reutiliza a função de largada anterior e inclui todos os espectadores.
alter function public.start_race(text) rename to start_race_before_spectators;
revoke all on function public.start_race_before_spectators(text) from public, anon, authenticated;

create or replace function public.start_race(p_room_code text)
returns public.rooms
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
begin
  update public.players set is_spectator = false
    where room_id = (select id from public.rooms where code = upper(p_room_code));
  v_room := public.start_race_before_spectators(p_room_code);
  return v_room;
end;
$$;

revoke all on function public.start_race(text) from public, anon;
grant execute on function public.start_race(text) to authenticated;

create or replace function public.repair_room_after_player_leave()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_next uuid;
begin
  select id into v_next
  from public.players
  where room_id = old.room_id
    and is_spectator = false
    and finish_position is null
  order by joined_at, id
  limit 1;

  if v_next is not null then
    update public.rooms
    set current_player_id = coalesce(current_player_id, v_next),
        pending_item = case
          when (pending_item->>'player_id')::uuid = old.id then null
          else pending_item
        end
    where id = old.room_id;
  else
    update public.rooms
    set current_player_id = null,
        pending_item = null
    where id = old.room_id;
  end if;

  return old;
end;
$$;
