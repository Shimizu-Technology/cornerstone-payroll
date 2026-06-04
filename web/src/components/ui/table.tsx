import { forwardRef, type HTMLAttributes, type TdHTMLAttributes, type ThHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

interface TableProps extends HTMLAttributes<HTMLTableElement> {
  containerClassName?: string;
  stickyHeader?: boolean;
}

interface TableBodyProps extends HTMLAttributes<HTMLTableSectionElement> {
  striped?: boolean;
}

interface StickyCellProps {
  stickyLeft?: boolean;
}

const Table = forwardRef<HTMLTableElement, TableProps>(
  ({ className, containerClassName, stickyHeader = false, ...props }, ref) => (
    <div className={cn('max-w-full overflow-auto overscroll-x-contain', containerClassName)}>
      <table
        ref={ref}
        className={cn(
          'w-full caption-bottom text-sm',
          stickyHeader && '[&_thead_th]:sticky [&_thead_th]:top-0 [&_thead_th]:z-20',
          className
        )}
        {...props}
      />
    </div>
  )
);
Table.displayName = 'Table';

const TableHeader = forwardRef<HTMLTableSectionElement, HTMLAttributes<HTMLTableSectionElement>>(
  ({ className, ...props }, ref) => (
    <thead ref={ref} className={cn('bg-gray-50', className)} {...props} />
  )
);
TableHeader.displayName = 'TableHeader';

const TableBody = forwardRef<HTMLTableSectionElement, TableBodyProps>(
  ({ className, striped = false, ...props }, ref) => (
    <tbody
      ref={ref}
      className={cn(
        'divide-y divide-gray-200',
        striped && '[&_tr:nth-child(odd)]:bg-white [&_tr:nth-child(even)]:bg-slate-100',
        className
      )}
      {...props}
    />
  )
);
TableBody.displayName = 'TableBody';

const TableFooter = forwardRef<HTMLTableSectionElement, HTMLAttributes<HTMLTableSectionElement>>(
  ({ className, ...props }, ref) => (
    <tfoot
      ref={ref}
      className={cn('bg-gray-50 font-medium', className)}
      {...props}
    />
  )
);
TableFooter.displayName = 'TableFooter';

const TableRow = forwardRef<HTMLTableRowElement, HTMLAttributes<HTMLTableRowElement>>(
  ({ className, ...props }, ref) => (
    <tr
      ref={ref}
      className={cn('transition-colors hover:bg-gray-50', className)}
      {...props}
    />
  )
);
TableRow.displayName = 'TableRow';

const TableHead = forwardRef<HTMLTableCellElement, ThHTMLAttributes<HTMLTableCellElement> & StickyCellProps>(
  ({ className, stickyLeft = false, ...props }, ref) => (
    <th
      ref={ref}
      className={cn(
        'px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider',
        stickyLeft && 'sticky left-0 z-50 border-r border-slate-200 bg-gray-50 shadow-[12px_0_18px_-14px_rgba(15,23,42,0.55)]',
        className
      )}
      {...props}
    />
  )
);
TableHead.displayName = 'TableHead';

const TableCell = forwardRef<HTMLTableCellElement, TdHTMLAttributes<HTMLTableCellElement> & StickyCellProps>(
  ({ className, stickyLeft = false, ...props }, ref) => (
    <td
      ref={ref}
      className={cn(
        'px-6 py-4 whitespace-nowrap',
        stickyLeft && 'sticky left-0 z-10 border-r border-slate-200 bg-inherit shadow-[12px_0_18px_-14px_rgba(15,23,42,0.45)]',
        className
      )}
      {...props}
    />
  )
);
TableCell.displayName = 'TableCell';

export {
  Table,
  TableHeader,
  TableBody,
  TableFooter,
  TableHead,
  TableRow,
  TableCell,
};
