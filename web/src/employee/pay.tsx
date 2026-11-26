// Home and Pay: the latest check, the list by year, and the stub.
// Desktop (1024px+): Pay is the list on the left and the stub on the right,
// with Older and Newer. Phone: Pay opens directly on the full list by year,
// with the latest stub on top; a stub opens as its own screen.
import { useCallback, useMemo, useState, type ReactElement, type ReactNode } from 'react';
import { ArrowLeft, ArrowRight, Banknote, CalendarDays, ChevronLeft, ChevronRight, Download, FileText, House } from 'lucide-react';
import { Link, useLocation, useNavigate, useParams } from 'react-router';
import { formatDateRange } from '@/lib/display-date';
import { formatGuamDateTime } from '@/lib/utils';
import { EmployeeApiError } from './api';
import { askManager } from './brand';
import type { AmountLine, EarlierVersion, EarningLine, StatementDetail, StatementPage, StatementSummary, TaxLine } from './contracts';
import { useBrand, useHideAmounts, useReadySession } from './contexts';
import { useDownload } from './download';
import { focusHeadingOnNextScreen } from './focus';
import {
  comparisonLine, daysUntilLabel, formatHours, formatMoney, hoursLabel, longDate, paymentLine, paymentStatus, pdfDownloadLabel, shortDate, splitCurrencySegments, weekdayDate,
} from './format';
import { today } from './config';
import { Amount, HideAmountsToggle } from './HideAmounts';
import { Card, Chip, EmpButton, EmpButtonLink, LoadProblem, Page, Placeholder, SkeletonRows } from './ui';
import { isSessionError, useEmployeeData, type DataState } from './useEmployeeData';
import { useMediaQuery } from './useMediaQuery';

const WIDE_QUERY = '(min-width: 1024px)';

function Money({ value, fallback = '—' }: { value: string | null | undefined; fallback?: string }): ReactElement {
  const formatted = formatMoney(value);
  if (!formatted) return <span>{fallback}</span>;
  return <Amount>{formatted}</Amount>;
}

// ---------- Data ----------

type MoreState = 'idle' | 'working' | 'failed' | 'offline';

interface Statements {
  state: DataState<StatementPage>;
  reload: () => void;
  more: MoreState;
  /** Loads the next page onto the list, or null when there isn't one (or it's loading). */
  showMore: (() => void) | null;
}

/**
 * One year of checks (or the newest page across years when `year` is null).
 * "Show more" adds the next page to the year's list in session memory, so the
 * rows already shown stay while it loads, and are all still there after
 * opening a stub and coming back.
 */
function useStatements(year: number | null): Statements {
  const { api, state: session, reportError } = useReadySession();
  const linkId = session.link.id;
  const { state, reload, update } = useEmployeeData<StatementPage>(
    `statements:${year ?? 'latest'}`,
    (client, id, signal) => client.statements(id, { year, page: 1 }, signal),
  );
  const [more, setMore] = useState<{ year: number | null; state: MoreState }>({ year, state: 'idle' });
  const moreState = more.year === year ? more.state : 'idle';
  const loaded = state.status === 'ready' ? state.data : null;
  const nextPage = loaded?.nextPage ?? null;
  const showMore = loaded && nextPage && moreState !== 'working' ? (): void => {
    setMore({ year, state: 'working' });
    api.statements(linkId, { year, page: nextPage }).then((next) => {
      const known = new Set(loaded.statements.map((s) => s.id));
      update({
        statements: [...loaded.statements, ...next.statements.filter((s) => !known.has(s.id))],
        years: loaded.years.length ? loaded.years : next.years,
        nextPage: next.nextPage,
      });
      setMore({ year, state: 'idle' });
    }, (error: unknown) => {
      if (isSessionError(error)) reportError(error);
      else setMore({ year, state: error instanceof EmployeeApiError && error.kind === 'offline' ? 'offline' : 'failed' });
    });
  } : null;
  return { state, reload, more: moreState, showMore };
}

function useStatement(id: string | null): { state: DataState<StatementDetail | null>; reload: () => void } {
  return useEmployeeData<StatementDetail | null>(id ? `statement:${id}` : null, async (api, linkId, signal) => {
    try {
      return await api.statement(linkId, id!, signal);
    } catch (error) {
      if (error instanceof EmployeeApiError && error.kind === 'resource_not_found') return null;
      throw error;
    }
  });
}

/** Payroll checks first, then "From QuickBooks records": the order the list shows and Older/Newer walk. */
function inListOrder(statements: StatementSummary[]): StatementSummary[] {
  return [...statements.filter((s) => s.source === 'payroll'), ...statements.filter((s) => s.source === 'quickbooks')];
}

/** ?year=2025 from the address, or null. */
function yearParam(search: string): number | null {
  const year = Number(new URLSearchParams(search).get('year'));
  return Number.isInteger(year) && year > 1900 && year < 3000 ? year : null;
}

// ---------- Pieces ----------

function PaidLine({ statement }: { statement: StatementSummary }): ReactElement {
  const status = paymentStatus(statement.payment);
  const method = paymentLine(statement.payment);
  return (
    <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-neutral-700">
      <span>{status?.label === 'Voided' ? `Pay date ${longDate(statement.payDate)}` : `Paid ${longDate(statement.payDate)}`}</span>
      {method && <><span aria-hidden="true">·</span><span>{method}</span></>}
      {status && status.label !== 'Paid' && <Chip tone={status.tone}>{status.label}</Chip>}
      {statement.corrected && <Chip tone="warn">Corrected</Chip>}
    </p>
  );
}

function MaskedText({ text }: { text: string }): ReactElement {
  const segments = splitCurrencySegments(text);
  if (segments.length === 1 && !segments[0].isMoney) return <>{text}</>;
  return (
    <>
      {segments.map((segment, index) => (
        segment.isMoney ? <Amount key={index}>{segment.text}</Amount> : <span key={index}>{segment.text}</span>
      ))}
    </>
  );
}

function Comparison({ statement, statements }: { statement: StatementSummary; statements: StatementSummary[] }): ReactElement | null {
  const { hidden } = useHideAmounts();
  // While amounts are masked, keep the hours comparison visible and hide only the money part.
  const line = comparisonLine(statement, statements, { hideMoney: hidden });
  if (!line) return null;
  return <p className="emp-compare">{line}</p>;
}

function StatementRow({ statement, selected, to, onSelect }: { statement: StatementSummary; selected?: boolean; to: string; onSelect?: () => void }): ReactElement {
  const hours = hoursLabel(statement.totalHours);
  const period = formatDateRange(statement.periodStart, statement.periodEnd);
  const status = paymentStatus(statement.payment);
  const details = [period, hours].filter(Boolean).join(' · ');
  return (
    <li>
      <Link
        to={to}
        className="emp-row"
        aria-current={selected ? 'page' : undefined}
        onClick={() => { onSelect?.(); focusHeadingOnNextScreen(); }}
      >
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-2">
            <span className="emp-row-title">{shortDate(statement.payDate)}</span>
            {status?.tone === 'bad' && <Chip tone="bad">{status.label}</Chip>}
            {statement.corrected && <Chip tone="warn">Corrected</Chip>}
          </span>
          {statement.notice && <span className="emp-row-sub">{statement.notice}</span>}
          {details && <span className="emp-row-sub">{details}</span>}
        </span>
        {!statement.withdrawn && <span className="emp-row-amount"><Money value={statement.netPay} /></span>}
        <ChevronRight aria-hidden="true" className="size-5 shrink-0 text-neutral-400" />
      </Link>
    </li>
  );
}

function StatementList({ statements, selectedId, linkTo }: { statements: StatementSummary[]; selectedId?: string | null; linkTo: (s: StatementSummary) => string }): ReactElement {
  const payroll = statements.filter((s) => s.source === 'payroll');
  const quickbooks = statements.filter((s) => s.source === 'quickbooks');
  return (
    <div className="space-y-4">
      {payroll.length > 0 && (
        <ul className="emp-rows" aria-label="Paychecks">
          {payroll.map((s) => <StatementRow key={s.id} statement={s} selected={s.id === selectedId} to={linkTo(s)} />)}
        </ul>
      )}
      {quickbooks.length > 0 && (
        <section aria-labelledby="emp-qb-heading" className="space-y-2">
          <div>
            <h3 id="emp-qb-heading" className="emp-h3">From QuickBooks records</h3>
            <p className="emp-hint">Checks paid before this app started.</p>
          </div>
          <ul className="emp-rows" aria-label="From QuickBooks records">
            {quickbooks.map((s) => <StatementRow key={s.id} statement={s} selected={s.id === selectedId} to={linkTo(s)} />)}
          </ul>
        </section>
      )}
    </div>
  );
}

function NoPayYet(): ReactElement {
  return (
    <Placeholder icon={Banknote} title="No pay stubs yet">
      <p>Your first pay stub will show here after your first payday in this app.</p>
    </Placeholder>
  );
}

/** Pay switched off for this employer, or not built on the API yet: say what will be here. */
function PayComingSoon(): ReactElement {
  return (
    <Placeholder icon={Banknote} title="Your pay stubs will show here">
      <p>Each paycheck will be listed here with its pay stub.</p>
    </Placeholder>
  );
}

// ---------- Home ----------

function LatestPay({ statement, statements }: { statement: StatementSummary; statements: StatementSummary[] }): ReactElement {
  const hours = hoursLabel(statement.totalHours);
  if (statement.withdrawn) return <p role="status">{statement.notice}</p>;
  return (
    <div className="space-y-4">
      <div>
        <p className="emp-label-quiet">Take-home pay <span className="emp-term">(net pay)</span></p>
        <p className="emp-hero-amount"><Money value={statement.netPay} /></p>
        <PaidLine statement={statement} />
        {statement.notice && <p role="status">{statement.notice}</p>}
        {hours && <p className="text-neutral-700">{hours}</p>}
        <Comparison statement={statement} statements={statements} />
      </div>
      <EmpButtonLink to={`/pay/${statement.id}`} block onClick={focusHeadingOnNextScreen}>
        <FileText aria-hidden="true" className="size-6" />
        View pay stub
      </EmpButtonLink>
    </div>
  );
}

function YearSoFar({ latest }: { latest: StatementSummary }): ReactElement {
  const { state, reload } = useStatement(latest.id);
  if (state.status === 'loading') return <SkeletonRows rows={2} label="Loading this year's totals" />;
  if (state.status === 'error') return <LoadProblem kind={state.kind} onRetry={reload} what="this year's totals" />;
  const detail = state.data;
  if (!detail) return <p className="emp-hint">No year-to-date totals are available for this pay stub.</p>;
  return (
    <div className="space-y-2">
      <dl className="emp-totals">
        <div><dt>Take-home pay</dt><dd><Money value={detail.ytdNet} /></dd></div>
        <div><dt>Pay before taxes <span className="emp-term">(gross)</span></dt><dd><Money value={detail.ytdGross} /></dd></div>
      </dl>
      <p className="emp-hint">{detail.taxYear} through {shortDate(detail.payDate)}</p>
    </div>
  );
}

function QuestionsCard(): ReactElement {
  const brand = useBrand();
  return (
    <Card title="Questions about your pay?">
      <p className="text-neutral-700">{askManager(brand)}</p>
      <Link to="/help" className="emp-link mt-2" onClick={focusHeadingOnNextScreen}>Go to Help</Link>
    </Card>
  );
}

function FormerNotice(): ReactElement | null {
  const { state, isFormer } = useReadySession();
  if (!isFormer) return null;
  const until = state.link.formerAccessUntil ?? state.info.formerAccessUntil;
  return (
    <div className="emp-notice-inline" role="note">
      <p className="font-bold">You're viewing your past pay</p>
      <p className="text-neutral-700">
        You can see your pay stubs and tax forms{until ? ` until ${longDate(until)}` : ''}. Nothing here can be changed.
      </p>
    </div>
  );
}

function NextPayday(): ReactElement | null {
  const { state, isFormer } = useReadySession();
  const date = state.info.nextPayday;
  // Only a date the API is sure of (§8a), never for former employees, and never an amount.
  if (!date || isFormer) return null;
  // Counted in Guam days, whatever zone the phone is set to.
  const until = daysUntilLabel(date, today());
  if (!until) return null;
  return (
    <div className="emp-payday">
      <CalendarDays aria-hidden="true" className="size-6 shrink-0 text-[var(--action)]" />
      <div className="min-w-0 flex-1">
        <p className="emp-label-quiet">Next payday</p>
        <p className="font-bold">{weekdayDate(date)}</p>
      </div>
      <Chip tone="brand">{until}</Chip>
    </div>
  );
}

/** Desktop: latest pay and recent pay on the left, the year and questions on the right. Phone: one column. */
export function HomeTab(): ReactElement {
  const { state: session } = useReadySession();
  const name = session.info.firstName;
  const stubsOn = session.info.features.stubs;
  return (
    <Page title={name ? `Hi, ${name}` : 'Welcome'}>
      <FormerNotice />
      <NextPayday />
      {stubsOn ? <HomeWithPay /> : (
        <div className="emp-home-grid">
          <div className="emp-column">
            <Card title="Latest pay">
              <Placeholder icon={House} title="Your latest pay will show here">
                <p>You'll see your take-home pay and your pay stub here as soon as they're added.</p>
              </Placeholder>
            </Card>
            <Card title="Recent pay">
              <Placeholder icon={Banknote} title="Your recent paychecks will show here">
                <p>Each one links to its pay stub.</p>
              </Placeholder>
            </Card>
          </div>
          <div className="emp-column emp-wide-only">
            <Card title="This year so far">
              <Placeholder icon={CalendarDays} title="Your totals for the year will show here">
                <p>Take-home pay and pay before taxes, added up.</p>
              </Placeholder>
            </Card>
            <QuestionsCard />
          </div>
        </div>
      )}
    </Page>
  );
}

function HomeWithPay(): ReactElement {
  const { state, reload } = useStatements(null);
  const statements = state.status === 'ready' ? inListOrder(state.data.statements) : [];
  const latest = statements[0];
  const recent = statements.slice(1, 4);
  const latestActive = statements.find((statement) => !statement.withdrawn);
  const body = (content: (latestCheck: StatementSummary) => ReactNode, empty: ReactNode): ReactNode => {
    if (state.status === 'loading') return <SkeletonRows label="Loading your pay" />;
    if (state.status === 'error') return <LoadProblem kind={state.kind} onRetry={reload} what="your pay" />;
    return latest ? content(latest) : empty;
  };
  return (
    <div className="emp-home-grid">
      <div className="emp-column">
        <Card title="Latest pay" action={latest ? <HideAmountsToggle /> : undefined}>
          {body((check) => <LatestPay statement={check} statements={statements} />, <NoPayYet />)}
        </Card>
        {(state.status !== 'ready' || recent.length > 0) && (
          <Card title="Recent pay">
            {body(() => (
              <div className="space-y-2">
                <StatementList statements={recent} linkTo={(s) => `/pay/${s.id}`} />
                <Link to="/pay" className="emp-link" onClick={focusHeadingOnNextScreen}>See all pay stubs</Link>
              </div>
            ), null)}
          </Card>
        )}
      </div>
      <div className="emp-column emp-wide-only">
        <Card title="This year so far">
          {body(() => latestActive ? <YearSoFar latest={latestActive} /> : null, <p className="text-neutral-600">Your totals will show here after your first payday.</p>)}
        </Card>
        <QuestionsCard />
      </div>
    </div>
  );
}

// ---------- Pay ----------

function YearPicker({ years, year, onChange }: { years: number[]; year: number; onChange: (year: number) => void }): ReactElement | null {
  if (years.length < 2) return null;
  return (
    <div className="emp-segmented" role="group" aria-label="Year">
      {years.map((y) => (
        <button key={y} type="button" className="emp-segment" aria-pressed={y === year} onClick={() => onChange(y)}>{y}</button>
      ))}
    </div>
  );
}

/** The list for one year, with a year switch and "Show more". */
function PayHistory({ selectedId, linkTo, year, onYear }: { selectedId?: string | null; linkTo: (s: StatementSummary) => string; year: number; onYear: (year: number) => void }): ReactElement {
  const newest = useStatements(null);
  const { state, reload, more, showMore } = useStatements(year);
  const years = useMemo(() => {
    const known = newest.state.status === 'ready' ? newest.state.data.years : [];
    const listed = state.status === 'ready' ? state.data.years : [];
    const all = new Set([...known, ...listed, year]);
    return [...all].sort((a, b) => b - a);
  }, [newest.state, state, year]);

  return (
    <div className="space-y-4">
      {years.length >= 2 ? <YearPicker years={years} year={year} onChange={onYear} /> : <p className="emp-h3">{year}</p>}
      {state.status === 'loading' && <SkeletonRows rows={5} label="Loading your pay stubs" />}
      {state.status === 'error' && <LoadProblem kind={state.kind} onRetry={reload} what="your pay stubs" />}
      {state.status === 'ready' && (state.data.statements.length === 0
        ? <p className="text-neutral-600">No pay stubs in {year}.</p>
        : (
          <>
            <StatementList statements={state.data.statements} selectedId={selectedId} linkTo={linkTo} />
            {state.data.nextPage && (
              <EmpButton variant="secondary" block onClick={() => showMore?.()} disabled={more === 'working'} aria-busy={more === 'working'}>
                {more === 'working' ? 'Loading more…' : 'Show more'}
              </EmpButton>
            )}
            {more === 'failed' && <p className="emp-field-error" role="alert">Couldn't load more pay stubs. Try again.</p>}
            {more === 'offline' && <p className="emp-field-error" role="alert">You're offline. Connect to load more pay stubs.</p>}
          </>
        ))}
    </div>
  );
}

/** The year Pay opens on: the newest year with checks. Null while the newest checks load or if they failed. */
function useDefaultYear(): { year: number | null; newest: Statements } {
  const newest = useStatements(null);
  if (newest.state.status !== 'ready') return { year: null, newest };
  const first = newest.state.data.statements[0];
  return { year: newest.state.data.years[0] ?? (first ? first.taxYear : Number(today().slice(0, 4))), newest };
}

/** /pay, /pay/all and /pay/:id. */
export function PayTab(): ReactElement {
  const { state: session } = useReadySession();
  const wide = useMediaQuery(WIDE_QUERY);
  if (!session.info.features.stubs) {
    return (
      <Page title="Pay stubs">
        <div className="emp-pay-grid">
          <Card title="Your pay"><PayComingSoon /></Card>
          <Card title="Pay stub" className="emp-wide-only">
            <Placeholder icon={FileText} title="Pay stub details will show here">
              <p>Pick a paycheck to see what you earned, what was taken out and your take-home pay.</p>
            </Placeholder>
          </Card>
        </div>
      </Page>
    );
  }
  return wide ? <PayDesktop /> : <PayPhone />;
}

function PayDesktop(): ReactElement {
  const { statementId } = useParams();
  const location = useLocation();
  const navigate = useNavigate();
  const { year: defaultYear, newest } = useDefaultYear();
  // The year lives in the address (?year=), like the phone's list, so a
  // reload or Back keeps it. A stub opened without one (from Home or an
  // email) shows its own year's list.
  const selected = useStatement(statementId ?? null);
  // The year the API lists the stub under, which a check date can't move.
  const stubYear = selected.state.status === 'ready' ? selected.state.data?.taxYear : null;
  const year = yearParam(location.search) ?? stubYear ?? (statementId && selected.state.status === 'loading' ? null : defaultYear);
  const { state } = useStatements(year);

  const listed = state.status === 'ready' ? inListOrder(state.data.statements) : [];
  const fallbackId = listed[0]?.id ?? (newest.state.status === 'ready' ? inListOrder(newest.state.data.statements)[0]?.id : undefined);
  const selectedId = statementId ?? fallbackId ?? null;
  const suffix = year ? `?year=${year}` : '';
  const hasAmounts = listed.length > 0
    || (newest.state.status === 'ready' && newest.state.data.statements.length > 0)
    || Boolean(selected.state.status === 'ready' && selected.state.data);

  return (
    <Page title="Pay stubs" actions={hasAmounts ? <HideAmountsToggle /> : undefined}>
      <div className="emp-pay-grid">
        <Card title="Your pay">
          {year === null
            ? (newest.state.status === 'error' ? <LoadProblem kind={newest.state.kind} onRetry={newest.reload} what="your pay stubs" /> : <SkeletonRows rows={5} label="Loading your pay stubs" />)
            : newest.state.status === 'ready' && newest.state.data.statements.length === 0 ? <NoPayYet />
              : (
                <PayHistory
                  year={year}
                  onYear={(y) => navigate(`/pay?year=${y}`, { replace: true })}
                  selectedId={selectedId}
                  linkTo={(s) => `/pay/${s.id}${suffix}`}
                />
              )}
        </Card>
        <Card title="Pay stub">
          {selectedId
            ? <StubDetail id={selectedId} siblings={listed} linkSuffix={suffix} />
            : (
              <Placeholder icon={FileText} title="Pay stub details will show here">
                <p>Pick a paycheck to see what you earned, what was taken out and your take-home pay.</p>
              </Placeholder>
            )}
        </Card>
      </div>
    </Page>
  );
}

function PayPhone(): ReactElement {
  const { statementId } = useParams();
  // Keyed, so each stub opens as a new screen: scrolled to the top, focus on its heading.
  if (statementId) return <StubScreen key={statementId} id={statementId} />;
  return <PayListPhone />;
}

function BackLink({ to, children }: { to: string; children: ReactNode }): ReactElement {
  return (
    <Link to={to} className="emp-back self-start" onClick={focusHeadingOnNextScreen}>
      <ChevronLeft aria-hidden="true" className="size-[26px]" />
      {children}
    </Link>
  );
}

function PayListPhone(): ReactElement {
  const { year: defaultYear, newest } = useDefaultYear();
  const location = useLocation();
  const navigate = useNavigate();
  // The year lives in the address so Back from a stub returns to it.
  const year = yearParam(location.search) ?? defaultYear;
  let body: ReactNode;
  if (newest.state.status === 'ready' && newest.state.data.statements.length === 0) {
    body = <NoPayYet />;
  } else if (year !== null) {
    body = <PayHistory year={year} onYear={(y) => navigate(`/pay?year=${y}`, { replace: true })} linkTo={(s) => `/pay/${s.id}?year=${year}`} />;
  } else if (newest.state.status === 'error') {
    body = <LoadProblem kind={newest.state.kind} onRetry={newest.reload} what="your pay stubs" />;
  } else {
    body = <SkeletonRows rows={5} label="Loading your pay stubs" />;
  }
  const hasAmounts = newest.state.status === 'ready' && newest.state.data.statements.length > 0;
  return (
    <Page title="Pay stubs" actions={hasAmounts ? <HideAmountsToggle /> : undefined}>
      <Card>{body}</Card>
    </Page>
  );
}

function StubScreen({ id }: { id: string }): ReactElement {
  const location = useLocation();
  const year = yearParam(location.search);
  const suffix = year ? `?year=${year}` : '';
  const back = `/pay${suffix}`;
  const list = useStatements(year);
  const statement = useStatement(id);
  const siblings = list.state.status === 'ready' ? inListOrder(list.state.data.statements) : [];
  const hasAmounts = statement.state.status === 'ready' && statement.state.data !== null;
  return (
    <Page title="Pay stub" actions={hasAmounts ? <HideAmountsToggle /> : undefined} before={<BackLink to={back}>Pay</BackLink>}>
      <Card>
        <StubDetailView state={statement.state} reload={statement.reload} siblings={siblings} linkSuffix={suffix} newScreen />
      </Card>
    </Page>
  );
}

// ---------- The stub ----------

function StubPdfButton({ id, filename, label }: { id: string; filename: string; label: string }): ReactElement {
  const { api, state: session } = useReadySession();
  const { hidden } = useHideAmounts();
  const linkId = session.link.id;
  const fetchPdf = useCallback(() => api.statementPdf(linkId, id), [api, linkId, id]);
  const { state, start } = useDownload(fetchPdf, filename);
  const buttonLabel = pdfDownloadLabel(label, hidden);
  return (
    <div className="space-y-2">
      <EmpButton variant="secondary" block className="emp-narrow-button" onClick={start} disabled={state === 'working'} aria-busy={state === 'working'}>
        <Download aria-hidden="true" className="size-6" />
        {state === 'working' ? 'Downloading…' : buttonLabel}
      </EmpButton>
      {state === 'failed' && <p className="emp-field-error" role="alert">Couldn't download the PDF. Try again.</p>}
      {state === 'offline' && <p className="emp-field-error" role="alert">You're offline. Connect to download the PDF.</p>}
    </div>
  );
}

function EarlierStubs({ versions, payDate }: { versions: EarlierVersion[]; payDate: string }): ReactElement {
  return (
    <details className="rounded-xl border border-neutral-200 px-3">
      <summary className="min-h-11 cursor-pointer py-2.5 font-semibold">Corrected — see the original</summary>
      <p className="pb-3 text-sm text-neutral-700">Earlier stubs are available as they were issued.</p>
      <ul className="divide-y divide-neutral-200">
        {versions.map((version, index) => {
          const original = index === versions.length - 1;
          const title = original ? 'Original pay stub' : 'Earlier correction';
          return (
            <li key={version.id} className="space-y-2 py-3">
              <h3 className="emp-h3">{title}</h3>
              {version.postedAt && <p className="text-sm text-neutral-700">Posted {formatGuamDateTime(version.postedAt, { second: undefined })}</p>}
              {version.paymentLine && <p className="text-sm text-neutral-700">{version.paymentLine}</p>}
              <StubPdfButton id={version.id}
                filename={original ? `original-pay-stub-${payDate}.pdf` : `earlier-pay-stub-${payDate}-${version.id}.pdf`}
                label={original ? 'Download original PDF' : 'Download earlier PDF'} />
            </li>
          );
        })}
      </ul>
    </details>
  );
}

function isYtdOnlyEarning(line: EarningLine): boolean {
  return line.amount !== null && Number(line.amount) === 0 && Number(line.ytd) !== 0
    && !Number(line.hours) && line.rate === null;
}

function EarningRow({ line }: { line: EarningLine }): ReactElement {
  const hours = formatHours(line.hours);
  const rate = formatMoney(line.rate);
  const hasHours = Boolean(hours && Number(line.hours) !== 0);
  return (
    <tr className={isYtdOnlyEarning(line) ? 'emp-ytd-only' : undefined}>
      <th scope="row">
        <span className="block"><MaskedText text={line.label} /></span>
        {hasHours && (
          <span className="emp-term block">
            {hours} hrs{rate && <> × <Amount>{rate}</Amount></>}
          </span>
        )}
      </th>
      <td><Money value={line.amount} /></td>
      <td className="emp-ytd"><Money value={line.ytd} /></td>
    </tr>
  );
}

function AmountRow({ line, tax }: { line: TaxLine; tax: true } | { line: AmountLine; tax?: false }): ReactElement {
  const label = tax ? line.displayLabel ?? line.label : line.label;
  const term = tax && line.kind === 'guam_income_tax' ? 'Withholding'
    : tax && (line.kind === 'social_security' || line.kind === 'medicare' || line.kind === 'additional_medicare') ? 'FICA' : null;
  return (
    <tr>
      <th scope="row">
        <span className="block"><MaskedText text={label} /></span>
        {term && <span className="emp-term block">{term}</span>}
      </th>
      <td><Money value={line.amount} /></td>
      <td className="emp-ytd"><Money value={line.ytd} /></td>
    </tr>
  );
}

function StubTable({ caption, term, total, children, ytdOnly = false }: { caption: string; term?: string; total?: string | null; children: ReactNode; ytdOnly?: boolean }): ReactElement {
  return (
    <table className={ytdOnly ? 'emp-stub-table emp-stub-table-ytd-only' : 'emp-stub-table'}>
      <caption>
        <span className="emp-caption-row">
          <span className="min-w-0">{caption}{term && <span className="emp-term"> ({term})</span>}</span>
          {total !== undefined && <span className="emp-stub-total"><Money value={total} /></span>}
        </span>
      </caption>
      <thead className="sr-only sm:not-sr-only">
        <tr><th scope="col">Item</th><th scope="col">This check</th><th scope="col" className="emp-ytd">This year</th></tr>
      </thead>
      <tbody>{children}</tbody>
    </table>
  );
}

function sum(lines: AmountLine[]): string | null {
  let cents = 0;
  for (const line of lines) {
    if (line.amount === null) return null;
    cents += Math.round(Number(line.amount) * 100);
  }
  return (cents / 100).toFixed(2);
}

function PrevNext({ siblings, id, linkSuffix, className, newScreen }: { siblings: StatementSummary[]; id: string; linkSuffix: string; className: string; newScreen: boolean }): ReactElement | null {
  const index = siblings.findIndex((s) => s.id === id);
  if (index < 0 || siblings.length < 2) return null;
  // The list is newest first: "Older" is the earlier check, "Newer" the later one.
  const older = siblings[index + 1];
  const newer = siblings[index - 1];
  const link = (target: StatementSummary | undefined, label: string, icon: ReactNode, after = false): ReactElement => (target
    ? (
      <Link
        to={`/pay/${target.id}${linkSuffix}`}
        className="emp-btn emp-btn-secondary emp-btn-small"
        aria-label={`${label}: ${longDate(target.payDate)}`}
        onClick={newScreen ? focusHeadingOnNextScreen : undefined}
      >
        {!after && icon}{label}{after && icon}
      </Link>
    )
    : <span className="emp-btn emp-btn-secondary emp-btn-small" aria-disabled="true">{!after && icon}{label}{after && icon}</span>);
  return (
    <nav className={`emp-prevnext ${className}`} aria-label="Other pay stubs">
      {link(older, 'Older', <ArrowLeft aria-hidden="true" className="size-5" />)}
      {link(newer, 'Newer', <ArrowRight aria-hidden="true" className="size-5" />, true)}
    </nav>
  );
}

/** `newScreen`: on a phone each stub is its own screen, so Older and Newer move focus to its heading. */
function StubDetail({ id, siblings, linkSuffix = '', newScreen = false }: { id: string; siblings: StatementSummary[]; linkSuffix?: string; newScreen?: boolean }): ReactElement {
  const { state, reload } = useStatement(id);
  return <StubDetailView state={state} reload={reload} siblings={siblings} linkSuffix={linkSuffix} newScreen={newScreen} />;
}

function StubDetailView({
  state,
  reload,
  siblings,
  linkSuffix = '',
  newScreen = false,
}: {
  state: DataState<StatementDetail | null>;
  reload: () => void;
  siblings: StatementSummary[];
  linkSuffix?: string;
  newScreen?: boolean;
}): ReactElement {
  if (state.status === 'loading') return <SkeletonRows rows={6} label="Loading the pay stub" />;
  if (state.status === 'error') return <LoadProblem kind={state.kind} onRetry={reload} what="this pay stub" />;
  const stub = state.data;
  if (!stub) return (
    <div className="space-y-2">
      <p className="font-semibold" role="status">We couldn't find that pay stub.</p>
      <BackLink to={`/pay${linkSuffix}`}>Back to pay stubs</BackLink>
    </div>
  );
  if (stub.withdrawn) return <p role="status">{stub.notice}</p>;
  const period = formatDateRange(stub.periodStart, stub.periodEnd);
  const hours = hoursLabel(stub.totalHours);
  const quickbooks = stub.source === 'quickbooks';
  const hasOnlyYtdEarnings = stub.earnings.length > 0 && stub.earnings.every(isYtdOnlyEarning);
  return (
    <article className="emp-stub" aria-labelledby={`emp-stub-${stub.id}`}>
      <header className="space-y-2">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <h2 id={`emp-stub-${stub.id}`} className="emp-stub-title">{period || longDate(stub.payDate)}</h2>
          {/* Desktop: beside the heading. Phone: at the end of the stub, where the thumb is. */}
          <PrevNext siblings={siblings} id={stub.id} linkSuffix={linkSuffix} className="emp-prevnext-top" newScreen={newScreen} />
        </div>
        {quickbooks && <Chip tone="neutral">From QuickBooks records</Chip>}
        <PaidLine statement={stub} />
        {stub.notice && <p role="status">{stub.notice}</p>}
        {hours && <p className="text-neutral-700">{hours}</p>}
      </header>

      {stub.earlierVersions.length > 0 && <EarlierStubs key={stub.id} versions={stub.earlierVersions} payDate={stub.payDate} />}

      <div className="emp-net">
        <p className="emp-label-quiet">Take-home pay <span className="emp-term">(net pay)</span></p>
        <p className="emp-hero-amount"><Money value={stub.netPay} /></p>
        <Comparison statement={stub} statements={siblings} />
      </div>

      {stub.note && <p className="emp-hint"><MaskedText text={stub.note} /></p>}

      {hasOnlyYtdEarnings && <p className="emp-no-current-earnings emp-hint">No earnings this pay period.</p>}
      {stub.earnings.length > 0 && (
        <StubTable caption="Pay before taxes" term="gross pay" total={stub.grossPay} ytdOnly={hasOnlyYtdEarnings}>
          {stub.earnings.map((line, index) => <EarningRow key={`${line.label}-${index}`} line={line} />)}
        </StubTable>
      )}
      {stub.earnings.length === 0 && stub.grossPay && (
        <dl className="emp-totals"><div><dt>Pay before taxes <span className="emp-term">(gross)</span></dt><dd><Money value={stub.grossPay} /></dd></div></dl>
      )}
      {stub.taxes.length > 0 && (
        <StubTable caption="Taxes" total={sum(stub.taxes)}>
          {stub.taxes.map((line, index) => <AmountRow key={`${line.label}-${index}`} line={line} tax />)}
        </StubTable>
      )}
      {stub.deductions.length > 0 && (
        <StubTable caption="Deductions" total={sum(stub.deductions)}>
          {stub.deductions.map((line, index) => <AmountRow key={`${line.label}-${index}`} line={line} />)}
        </StubTable>
      )}
      {stub.otherPay.length > 0 && (
        <StubTable caption="Added after taxes" total={sum(stub.otherPay)}>
          {stub.otherPay.map((line, index) => <AmountRow key={`${line.label}-${index}`} line={line} />)}
        </StubTable>
      )}

      {(stub.ytdNet || stub.ytdGross) && (
        <section aria-label="This year so far" className="space-y-2">
          <h3 className="emp-h3">This year so far</h3>
          <dl className="emp-totals">
            {stub.ytdNet && <div><dt>Take-home pay</dt><dd><Money value={stub.ytdNet} /></dd></div>}
            {stub.ytdGross && <div><dt>Pay before taxes <span className="emp-term">(gross)</span></dt><dd><Money value={stub.ytdGross} /></dd></div>}
          </dl>
        </section>
      )}

      {(quickbooks ? stub.originalPdf : stub.pdfAvailable) && (
        <StubPdfButton id={stub.id} filename={`${quickbooks ? 'original-pay-stub' : 'pay-stub'}-${stub.payDate}.pdf`}
          label={quickbooks ? 'View original stub (PDF)' : 'Download PDF'} />
      )}
      {/* A QuickBooks note is the recorded-adjustment note: the amounts above include it, the PDF doesn't. */}
      {quickbooks && stub.originalPdf && stub.note && (
        <p className="emp-hint">This PDF is the original QuickBooks stub from before the recorded adjustment, so its amounts differ from the ones above.</p>
      )}
      <PrevNext siblings={siblings} id={stub.id} linkSuffix={linkSuffix} className="emp-prevnext-bottom" newScreen={newScreen} />
    </article>
  );
}

// Re-exported for the Help and Tax forms screens' "Questions" card.
export { QuestionsCard, FormerNotice };
