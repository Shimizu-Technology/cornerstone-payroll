import { useEffect, useId, useState } from 'react';
import { Input } from '@/components/ui/input';

export function TippedOccupationCodeSelect({ codes, value, onChange }: {
  codes: Record<string, string>;
  value: string;
  onChange: (code: string) => void;
}) {
  const listId = useId();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(-1);
  const options = Object.entries(codes).sort(([a], [b]) => a.localeCompare(b))
    .filter(([code, name]) => `${code} ${name}`.toLowerCase().includes(query.trim().toLowerCase()));
  const activeId = open && options[active] ? `${listId}-${options[active][0]}` : undefined;

  useEffect(() => {
    if (activeId) document.getElementById(activeId)?.scrollIntoView?.({ block: 'nearest' });
  }, [activeId]);

  function choose(code: string) {
    onChange(code);
    setOpen(false);
    setQuery('');
    setActive(-1);
  }

  return (
    <div className="min-w-0">
      <Input label="Treasury occupation code" placeholder="Search by code or occupation" role="combobox"
        autoComplete="off" aria-autocomplete="list" aria-expanded={open}
        aria-controls={open ? listId : undefined} aria-activedescendant={activeId}
        value={open ? query : value}
        onFocus={() => { setQuery(''); setActive(-1); setOpen(true); }}
        onClick={() => setOpen(true)}
        onBlur={() => { setOpen(false); setQuery(''); setActive(-1); }}
        onChange={(event) => { onChange(''); setQuery(event.target.value); setActive(-1); setOpen(true); }}
        onKeyDown={(event) => {
          if (event.key === 'Escape' && open) {
            event.preventDefault();
            setOpen(false);
            setQuery('');
            setActive(-1);
          } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            setOpen(true);
            if (options.length) {
              setActive(event.key === 'ArrowDown' ? Math.min(active + 1, options.length - 1) : active < 0 ? options.length - 1 : Math.max(active - 1, 0));
            }
          } else if (event.key === 'Enter' && open) {
            event.preventDefault();
            if (options[active]) choose(options[active][0]);
          }
        }} />
      {!open && value && <p className="mt-1 break-words text-sm text-neutral-600">{codes[value]}</p>}
      {open && (
        <>
          <ul id={listId} role="listbox" aria-label="Treasury occupations"
            className="mt-1 max-h-48 overflow-y-auto rounded-lg border border-neutral-200 bg-white">
            {options.map(([code, name], index) => (
              <li key={code} id={`${listId}-${code}`} role="option" aria-selected={code === value}
                className={`flex min-h-11 cursor-pointer items-center break-words px-3 py-2 text-sm hover:bg-primary-50 ${index === active ? 'bg-primary-100' : ''}`}
                onMouseDown={(event) => event.preventDefault()} onClick={() => choose(code)}>
                <span className="min-w-0">{code} · {name}</span>
              </li>
            ))}
          </ul>
          {options.length === 0 && <p role="status" className="mt-1 text-sm">No matching occupations.</p>}
        </>
      )}
    </div>
  );
}
