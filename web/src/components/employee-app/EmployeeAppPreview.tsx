import { useEffect, useRef, useState, type CSSProperties, type ReactElement, type ReactNode, type RefObject } from 'react';
import { Banknote, CircleHelp, FileText, House, Mail, MessageSquare, Phone, UserRound } from 'lucide-react';
import { cn } from '@/lib/utils';
import { brandRoleStyle, brandRoles } from '@/lib/tenant-brand-colors';
import { formatPhone } from '@/lib/display-phone';
import { possessive } from '@/lib/employee-app-text';
import type { HelpContact } from '@/services/employee-app-settings-api';

export type PreviewScreen = 'sign-in' | 'home' | 'help';
export type PreviewDevice = 'phone' | 'desktop';

export interface PreviewBrand {
  name: string;
  logoUrl: string | null;
  primaryColor: string | null;
  accentColor: string | null;
  mainPhone: string | null;
}

const CANVAS = { phone: { width: 375, height: 720 }, desktop: { width: 1200, height: 720 } } as const;

function useScaleToWidth(width: number): [RefObject<HTMLDivElement | null>, number] {
  const ref = useRef<HTMLDivElement | null>(null);
  const [scale, setScale] = useState(1);
  useEffect(() => {
    const node = ref.current;
    if (!node) return undefined;
    const update = () => setScale(Math.min(1, node.clientWidth / width) || 1);
    update();
    if (typeof ResizeObserver === 'undefined') return undefined;
    const observer = new ResizeObserver(update);
    observer.observe(node);
    return () => observer.disconnect();
  }, [width]);
  return [ref, scale];
}

function Mark({ brand, size }: { brand: PreviewBrand; size: number }): ReactElement {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [brand.logoUrl]);
  if (brand.logoUrl && !failed) {
    return <img src={brand.logoUrl} alt="" className="shrink-0 object-contain" style={{ height: size, width: size }} onError={() => setFailed(true)} />;
  }
  const letter = brand.name.match(/[\p{L}\p{N}]/u)?.[0]?.toUpperCase() ?? 'C';
  return (
    <span
      aria-hidden="true"
      className="grid shrink-0 place-items-center rounded-full font-bold text-white"
      style={{ height: size, width: size, background: 'var(--action)', fontSize: size * 0.45 }}
    >
      {letter}
    </span>
  );
}

function ActionButton({ children, block = false }: { children: ReactNode; block?: boolean }): ReactElement {
  return (
    <span
      className={cn('inline-flex min-h-[52px] items-center justify-center rounded-full px-6 text-[17px] font-semibold text-white', block && 'w-full')}
      style={{ background: 'var(--action)' }}
    >
      {children}
    </span>
  );
}

function AccentChip({ children }: { children: ReactNode }): ReactElement {
  return (
    <span className="inline-flex items-center rounded-full px-3 py-1 text-[15px] font-semibold" style={{ background: 'var(--accent)', color: 'var(--accent-ink)' }}>
      {children}
    </span>
  );
}

function SignInScreen({ brand }: { brand: PreviewBrand }): ReactElement {
  return (
    <div className="flex h-full flex-col justify-between bg-white px-6 pb-8 pt-16 text-center">
      <div className="flex flex-col items-center gap-4">
        <Mark brand={brand} size={96} />
        <p className="text-[28px] font-bold leading-tight text-slate-950">Your pay, on your phone</p>
        <p className="text-[17px] text-slate-600">See your pay stubs and tax forms from {brand.name} any time.</p>
      </div>
      <div className="space-y-4">
        <ActionButton block>Sign in</ActionButton>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-left text-[15px] text-slate-700">
          <p className="font-semibold text-slate-900">Can't sign in?</p>
          <p>Ask your manager at {brand.name}.</p>
          {brand.mainPhone && <p className="mt-1 font-semibold" style={{ color: 'var(--action)' }}>Call {formatPhone(brand.mainPhone)}</p>}
        </div>
      </div>
    </div>
  );
}

function PayHero(): ReactElement {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5">
      <p className="text-[15px] text-slate-600">Take-home pay <span className="text-[13px]">(net pay)</span></p>
      <p className="mt-1 text-[44px] font-bold tabular-nums leading-none text-slate-950">$612.40</p>
      <p className="mt-2 text-[15px] text-slate-600">Paid Thu, Nov 20 · 38.5 hours</p>
      <div className="mt-4"><ActionButton block>View pay stub</ActionButton></div>
    </div>
  );
}

function NextPayday(): ReactElement {
  return (
    <div className="flex items-center justify-between rounded-2xl border border-slate-200 bg-white p-4">
      <div>
        <p className="text-[15px] text-slate-600">Next payday</p>
        <p className="text-[17px] font-semibold text-slate-950">Thursday, Dec 4</p>
      </div>
      <AccentChip>In 10 days</AccentChip>
    </div>
  );
}

const TABS = [
  { label: 'Home', icon: House },
  { label: 'Pay', icon: Banknote },
  { label: 'Tax forms', icon: FileText },
  { label: 'My info', icon: UserRound },
  { label: 'Help', icon: CircleHelp },
];

function PhoneTabs({ active }: { active: 'Home' | 'Help' }): ReactElement {
  return (
    <div className="grid grid-cols-5 border-t border-slate-200 bg-white pb-5 pt-2">
      {TABS.map(({ label, icon: Icon }) => {
        const current = label === active;
        return (
          <span key={label} className="relative flex flex-col items-center gap-1 text-[12px] font-semibold" style={{ color: current ? 'var(--action)' : '#64748b' }}>
            {current && <span aria-hidden="true" className="absolute -top-2 h-1 w-8 rounded-full" style={{ background: 'var(--indicator)' }} />}
            <Icon aria-hidden="true" className="size-6" />
            {label}
          </span>
        );
      })}
    </div>
  );
}

function PhoneHeader({ brand }: { brand: PreviewBrand }): ReactElement {
  return (
    <div className="flex items-center gap-3 border-b-2 bg-white px-4 pb-3 pt-10" style={{ borderColor: 'var(--brand)' }}>
      <Mark brand={brand} size={40} />
      <span className="min-w-0 truncate text-[17px] font-bold text-slate-950">{brand.name}</span>
    </div>
  );
}

function DesktopHeader({ brand, active }: { brand: PreviewBrand; active: 'Home' | 'Help' }): ReactElement {
  return (
    <div className="flex h-[72px] items-center gap-8 border-b border-slate-200 bg-white px-10">
      <span className="flex items-center gap-3">
        <Mark brand={brand} size={44} />
        <span className="text-[18px] font-bold text-slate-950">{brand.name}</span>
      </span>
      <span className="flex h-full items-stretch gap-6">
        {TABS.map(({ label }) => (
          <span
            key={label}
            className="flex items-center border-b-[3px] text-[16px] font-semibold"
            style={{ borderColor: label === active ? 'var(--indicator)' : 'transparent', color: label === active ? 'var(--action)' : '#475569' }}
          >
            {label}
          </span>
        ))}
      </span>
      <span className="ml-auto text-[15px] text-slate-600">Jordan Sample</span>
    </div>
  );
}

function HelpBody({ brand, contacts }: { brand: PreviewBrand; contacts: HelpContact[] }): ReactElement {
  if (contacts.length === 0) {
    return (
      <div className="rounded-2xl border border-slate-200 bg-white p-5">
        <p className="text-[22px] font-bold text-slate-950">Questions about your pay or this app?</p>
        <p className="mt-2 text-[17px] text-slate-700">Ask your manager at {brand.name}.</p>
        {brand.mainPhone && (
          <div className="mt-4"><ActionButton block>Call {possessive(brand.name)} main line</ActionButton></div>
        )}
      </div>
    );
  }
  return (
    <div className="rounded-2xl border border-slate-200 bg-white">
      <p className="px-5 pt-5 text-[22px] font-bold text-slate-950">Ask {brand.name}</p>
      <p className="px-5 text-[15px] text-slate-600">These people can help with your pay or this app.</p>
      <ul className="mt-2 divide-y divide-slate-200">
        {contacts.map((contact, index) => (
          <li key={`${contact.name}-${index}`} className="flex items-center gap-3 px-5 py-4">
            <span className="min-w-0 flex-1">
              <span className="block break-words text-[17px] font-semibold text-slate-950">{contact.name}</span>
              {contact.role && <span className="block break-words text-[15px] text-slate-600">{contact.role}</span>}
            </span>
            {contact.phone && <ContactIcon label="Call" filled={index === 0}><Phone className="size-5" /></ContactIcon>}
            {contact.phone && contact.text_ok && <ContactIcon label="Text" filled={false}><MessageSquare className="size-5" /></ContactIcon>}
            {contact.email && <ContactIcon label="Email" filled={false}><Mail className="size-5" /></ContactIcon>}
          </li>
        ))}
      </ul>
    </div>
  );
}

function ContactIcon({ label, filled, children }: { label: string; filled: boolean; children: ReactNode }): ReactElement {
  return (
    <span
      aria-label={label}
      className="grid size-11 shrink-0 place-items-center rounded-full border"
      style={filled
        ? { background: 'var(--action)', borderColor: 'var(--action)', color: '#fff' }
        : { background: 'var(--action-tint)', borderColor: 'transparent', color: 'var(--action)' }}
    >
      {children}
    </span>
  );
}

function PhoneCanvas({ brand, screen, contacts }: { brand: PreviewBrand; screen: PreviewScreen; contacts: HelpContact[] }): ReactElement {
  if (screen === 'sign-in') return <SignInScreen brand={brand} />;
  const active = screen === 'home' ? 'Home' : 'Help';
  return (
    <div className="flex h-full flex-col bg-slate-50">
      <PhoneHeader brand={brand} />
      <div className="flex-1 space-y-3 overflow-hidden p-4">
        {screen === 'home' ? (
          <>
            <PayHero />
            <NextPayday />
          </>
        ) : (
          <HelpBody brand={brand} contacts={contacts} />
        )}
      </div>
      <PhoneTabs active={active} />
    </div>
  );
}

function DesktopCanvas({ brand, screen, contacts }: { brand: PreviewBrand; screen: PreviewScreen; contacts: HelpContact[] }): ReactElement {
  if (screen === 'sign-in') {
    return (
      <div className="grid h-full place-items-center bg-slate-50">
        <div className="h-[620px] w-[440px] overflow-hidden rounded-3xl border border-slate-200 shadow-sm">
          <SignInScreen brand={brand} />
        </div>
      </div>
    );
  }
  const active = screen === 'home' ? 'Home' : 'Help';
  return (
    <div className="flex h-full flex-col bg-slate-50">
      <DesktopHeader brand={brand} active={active} />
      <div className="mx-auto grid w-full max-w-[1120px] flex-1 grid-cols-[7fr_5fr] gap-6 px-10 py-8">
        {screen === 'home' ? (
          <>
            <PayHero />
            <div className="space-y-4">
              <NextPayday />
              <div className="rounded-2xl border border-slate-200 bg-white p-5">
                <p className="text-[17px] font-semibold text-slate-950">Questions about your pay?</p>
                <p className="mt-1 text-[15px] text-slate-600">{contacts[0] ? `Ask ${contacts[0].name}` : `Ask your manager at ${brand.name}.`}</p>
              </div>
            </div>
          </>
        ) : (
          <>
            <HelpBody brand={brand} contacts={contacts} />
            <div className="rounded-2xl border border-slate-200 bg-white p-5 text-[15px] text-slate-600">
              <p className="text-[17px] font-semibold text-slate-950">Common questions</p>
              <p className="mt-2">When is payday?</p>
              <p className="mt-1">How do I update my address?</p>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

const SCREEN_LABELS: Record<PreviewScreen, string> = { 'sign-in': 'Sign-in', home: 'Home', help: 'Help' };

/** A scaled, non-interactive picture of the employee app with this company's brand. */
export function EmployeeAppPreview({ brand, screen, device, contacts }: {
  brand: PreviewBrand;
  screen: PreviewScreen;
  device: PreviewDevice;
  contacts: HelpContact[];
}): ReactElement {
  const canvas = CANVAS[device];
  const [ref, scale] = useScaleToWidth(canvas.width);
  const style = brandRoleStyle(brandRoles(brand.primaryColor, brand.accentColor)) as CSSProperties;
  return (
    <div ref={ref} className="w-full">
      <div
        role="img"
        aria-label={`Preview of the ${SCREEN_LABELS[screen]} screen on a ${device}, with sample pay`}
        className={cn('relative mx-auto overflow-hidden border border-neutral-300 bg-white shadow-sm', device === 'phone' ? 'rounded-[28px]' : 'rounded-xl')}
        style={{ width: canvas.width * scale, height: canvas.height * scale }}
      >
        <div
          aria-hidden="true"
          className="pointer-events-none origin-top-left select-none font-sans"
          style={{ ...style, width: canvas.width, height: canvas.height, transform: `scale(${scale})` }}
        >
          {device === 'phone'
            ? <PhoneCanvas brand={brand} screen={screen} contacts={contacts} />
            : <DesktopCanvas brand={brand} screen={screen} contacts={contacts} />}
        </div>
      </div>
    </div>
  );
}
