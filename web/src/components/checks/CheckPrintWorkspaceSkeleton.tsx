import { Skeleton } from '@/components/ui/skeleton';

export function CheckPrintWorkspaceSkeleton() {
  return (
    <div className="grid min-h-0 flex-1 lg:grid-cols-[minmax(0,1fr)_380px]" aria-label="Loading check print workspace" aria-busy="true">
      <section className="border-r border-slate-200 p-5">
        <div className="mb-5 flex gap-2">
          <Skeleton className="h-9 w-24" />
          <Skeleton className="h-9 w-24" />
          <Skeleton className="h-9 w-28" />
        </div>
        <div className="overflow-hidden rounded-2xl border border-slate-200">
          <Skeleton className="h-11 w-full rounded-none" />
          {Array.from({ length: 6 }).map((_, index) => (
            <div key={index} className="grid grid-cols-[36px_90px_1fr_100px] gap-4 border-t border-slate-100 px-4 py-4">
              <Skeleton className="h-4 w-4" />
              <Skeleton className="h-5 w-full" />
              <Skeleton className="h-5 w-3/4" />
              <Skeleton className="h-5 w-full" />
            </div>
          ))}
        </div>
      </section>
      <aside className="space-y-4 bg-slate-50 p-5">
        <div className="rounded-2xl border border-slate-200 bg-white p-4">
          <Skeleton className="h-3 w-28" />
          <Skeleton className="mt-4 h-10 w-full" />
          <Skeleton className="mt-3 h-4 w-5/6" />
        </div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4">
          <Skeleton className="h-3 w-24" />
          <div className="mt-5 grid grid-cols-2 gap-4"><Skeleton className="h-14" /><Skeleton className="h-14" /></div>
        </div>
      </aside>
    </div>
  );
}
