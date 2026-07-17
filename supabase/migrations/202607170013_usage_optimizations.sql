-- Reduz Realtime, remove avatares órfãos e limpa visitantes antigos.

create or replace function public.notify_room_player_membership_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.rooms set updated_at = now()
  where id = coalesce(new.room_id, old.room_id);
  return coalesce(new, old);
end;
$$;

drop trigger if exists players_notify_room_after_insert on public.players;
create trigger players_notify_room_after_insert after insert on public.players
for each row execute function public.notify_room_player_membership_change();

drop trigger if exists players_notify_room_after_delete on public.players;
create trigger players_notify_room_after_delete after delete on public.players
for each row execute function public.notify_room_player_membership_change();

create or replace function public.delete_player_avatar()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from storage.objects
  where bucket_id = 'avatars'
    and name = old.owner_id::text || '/' || old.id::text || '.jpg';
  return old;
end;
$$;

drop trigger if exists players_delete_avatar on public.players;
create trigger players_delete_avatar after delete on public.players
for each row execute function public.delete_player_avatar();

create or replace function public.cleanup_old_anonymous_users()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_deleted integer;
begin
  delete from auth.users user_account
  where user_account.is_anonymous = true
    and coalesce(user_account.last_sign_in_at, user_account.created_at) < now() - interval '30 days'
    and not exists (select 1 from public.players p where p.owner_id = user_account.id)
    and not exists (select 1 from public.rooms r where r.owner_id = user_account.id)
    and not exists (
      select 1 from public.room_presence presence
      where presence.user_id = user_account.id
        and presence.last_seen_at >= now() - interval '2 minutes'
    );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.cleanup_old_anonymous_users() from public, anon;
grant execute on function public.cleanup_old_anonymous_users() to authenticated;

create or replace function public.cleanup_abandoned_rooms()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_deleted integer;
begin
  delete from public.room_presence where last_seen_at < now() - interval '2 minutes';
  delete from public.rooms room
  where not exists (
    select 1 from public.room_presence presence where presence.room_id = room.id
  ) and room.updated_at < now() - interval '2 minutes';
  get diagnostics v_deleted = row_count;
  perform public.cleanup_old_anonymous_users();
  return v_deleted;
end;
$$;

revoke all on function public.cleanup_abandoned_rooms() from public, anon;
grant execute on function public.cleanup_abandoned_rooms() to authenticated;
