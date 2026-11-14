import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Bell } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/context/AuthContext';
import type { Notification } from '@/types/database';

type Item = Pick<Notification, 'id' | 'booking_id' | 'title' | 'message' | 'created_at'> & { read_at: string | null };

// The member's in-app notifications (e.g. "You're in!" when a place opens from
// the waiting list). Opening the panel marks everything as read.
export function NotificationsBell() {
  const { t, i18n } = useTranslation();
  const { profile } = useAuth();
  const [items, setItems] = useState<Item[]>([]);
  const [open, setOpen] = useState(false);
  const [fresh, setFresh] = useState<Set<string>>(new Set());
  const ref = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    if (!profile) return;
    const { data } = await supabase
      .from('notifications')
      .select('id, booking_id, title, message, created_at, read_at')
      .eq('user_id', profile.id)
      .eq('delivery_channel', 'in_app')
      .order('created_at', { ascending: false })
      .limit(15);
    setItems((data || []) as Item[]);
  }, [profile]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 60_000);
    window.addEventListener('focus', load);
    return () => { window.clearInterval(timer); window.removeEventListener('focus', load); };
  }, [load]);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey); };
  }, [open]);

  if (!profile) return null;
  const unread = items.filter((i) => !i.read_at);

  async function toggle() {
    const next = !open;
    setOpen(next);
    if (next && unread.length > 0) {
      const ids = unread.map((i) => i.id);
      setFresh(new Set(ids));
      const now = new Date().toISOString();
      setItems((prev) => prev.map((i) => (ids.includes(i.id) ? { ...i, read_at: now } : i)));
      await supabase.from('notifications').update({ read_at: now }).in('id', ids);
    }
  }

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={toggle}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={`${t('v2.nav.notifications')}${unread.length ? ` (${unread.length})` : ''}`}
        className="relative flex h-10 w-10 items-center justify-center rounded-full text-slate-300 transition-colors hover:bg-ink-700 hover:text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-vsb-400"
      >
        <Bell className="h-5 w-5" aria-hidden />
        {unread.length > 0 && (
          <span className="absolute right-1 top-1 flex h-4 min-w-[1rem] items-center justify-center rounded-full bg-amber-500 px-1 text-[10px] font-bold leading-none text-ink">
            {unread.length > 9 ? '9+' : unread.length}
          </span>
        )}
      </button>
      {open && (
        <div role="dialog" aria-label={t('v2.nav.notifications')} className="animate-pop fixed inset-x-3 top-16 z-50 max-h-[70vh] overflow-y-auto border border-ink-600 bg-ink-800 shadow-2xl shadow-black/50 sm:absolute sm:inset-x-auto sm:right-0 sm:top-full sm:mt-2 sm:w-80">
          <p className="vsb-meta border-b border-ink-600 px-4 py-3">{t('v2.nav.notifications')}</p>
          {items.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">{t('v2.nav.noNotifications')}</p>
          ) : (
            <ul className="divide-y divide-ink-700">
              {items.map((n) => {
                const body = (
                  <>
                    <p className="flex items-center gap-2 text-sm font-bold text-chalk">
                      {fresh.has(n.id) && <span className="h-2 w-2 shrink-0 rounded-full bg-amber-500" aria-hidden />}
                      {n.title}
                    </p>
                    <p className="mt-1 text-sm text-slate-300">{n.message}</p>
                    <p className="mt-1 text-xs text-muted">{new Date(n.created_at).toLocaleString(i18n.language, { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })}</p>
                  </>
                );
                return (
                  <li key={n.id}>
                    {n.booking_id ? (
                      <Link to="/bookings" onClick={() => setOpen(false)} className="block px-4 py-3 hover:bg-ink-700">{body}</Link>
                    ) : (
                      <div className="px-4 py-3">{body}</div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
