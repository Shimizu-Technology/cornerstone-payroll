import { useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react';
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Move } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { cn } from '@/lib/utils';
import type { CheckLayoutResponse, CheckStockType } from '@/types';

type LayoutConfig = Record<string, unknown>;

type FieldSpec = {
  id: string;
  label: string;
  section: string;
  field: string;
  sample: string;
  align?: 'left' | 'right';
};

type FieldBox = FieldSpec & {
  x: number;
  y: number;
  width: number;
  height: number;
  fontSize: number;
  top: number;
  left: number;
};

interface CheckLayoutEditorProps {
  stockType: CheckStockType;
  offsetX: string;
  offsetY: string;
  layoutConfig: LayoutConfig;
  layout: CheckLayoutResponse | null;
  disabled?: boolean;
  onLayoutConfigChange: (config: LayoutConfig) => void;
  onOffsetChange: (axis: 'x' | 'y', value: string) => void;
}

const REGULAR_FIELDS: FieldSpec[] = [
  { id: 'check_face.date', label: 'Date', section: 'check_face', field: 'date', sample: '05/14/2026', align: 'right' },
  { id: 'check_face.payee', label: 'Payee', section: 'check_face', field: 'payee', sample: 'Jane Sample' },
  { id: 'check_face.payee_address', label: 'Address', section: 'check_face', field: 'payee_address', sample: '123 Marine Dr\nHagatna, GU 96910' },
  { id: 'check_face.amount', label: 'Amount', section: 'check_face', field: 'amount', sample: '1,245.67', align: 'right' },
  { id: 'check_face.amount_words', label: 'Amount Words', section: 'check_face', field: 'amount_words', sample: 'One thousand two hundred forty-five and 67/100' },
  { id: 'check_face.memo', label: 'Memo', section: 'check_face', field: 'memo', sample: 'Payroll 05/01/2026 - 05/14/2026' },
];

const FHB_FIELDS: FieldSpec[] = [
  { id: 'check_face.date', label: 'Check Date', section: 'check_face', field: 'date', sample: '05/14/2026', align: 'right' },
  { id: 'check_face.payee', label: 'Check Payee', section: 'check_face', field: 'payee', sample: 'Jane Sample' },
  { id: 'check_face.amount', label: 'Check Amount', section: 'check_face', field: 'amount', sample: '1,245.67', align: 'right' },
  { id: 'check_face.amount_words', label: 'Check Words', section: 'check_face', field: 'amount_words', sample: 'One thousand two hundred forty-five and 67/100' },
  { id: 'check_face.memo', label: 'Check Memo', section: 'check_face', field: 'memo', sample: 'Payroll 05/01/2026 - 05/14/2026' },
  { id: 'register.date', label: 'Register Date', section: 'register', field: 'date', sample: '05/14/2026' },
  { id: 'register.payee', label: 'Register Payee', section: 'register', field: 'payee', sample: 'Jane Sample' },
  { id: 'register.memo', label: 'Register Memo', section: 'register', field: 'memo', sample: 'Payroll' },
  { id: 'register.amount', label: 'Register Amount', section: 'register', field: 'amount', sample: '$1,245.67', align: 'right' },
];

const FIELD_HEIGHT = 18;
const POINTS_PER_INCH = 72;

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

function numberAt(value: unknown, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function deepMerge(base: LayoutConfig, overrides: LayoutConfig): LayoutConfig {
  const result: LayoutConfig = { ...base };
  Object.entries(overrides).forEach(([key, value]) => {
    const oldValue = result[key];
    if (isRecord(oldValue) && isRecord(value)) {
      result[key] = deepMerge(oldValue, value);
    } else {
      result[key] = value;
    }
  });
  return result;
}

function setNestedField(config: LayoutConfig, section: string, field: string, changes: LayoutConfig): LayoutConfig {
  const sectionConfig = isRecord(config[section]) ? config[section] as LayoutConfig : {};
  const fieldConfig = isRecord(sectionConfig[field]) ? sectionConfig[field] as LayoutConfig : {};

  return {
    ...config,
    [section]: {
      ...sectionConfig,
      [field]: {
        ...fieldConfig,
        ...changes,
      },
    },
  };
}

function fieldConfig(layoutConfig: LayoutConfig, spec: FieldSpec): LayoutConfig | null {
  const section = layoutConfig[spec.section];
  if (!isRecord(section)) return null;
  const field = section[spec.field];
  return isRecord(field) ? field : null;
}

function formatPoint(value: number) {
  return Number(value.toFixed(1));
}

function formatOffset(value: number) {
  return value.toFixed(3);
}

export function CheckLayoutEditor({
  stockType,
  offsetX,
  offsetY,
  layoutConfig,
  layout,
  disabled = false,
  onLayoutConfigChange,
  onOffsetChange,
}: CheckLayoutEditorProps) {
  const previewRef = useRef<HTMLDivElement>(null);
  const dragCleanupRef = useRef<(() => void) | null>(null);
  const [selectedId, setSelectedId] = useState<string>('check_face.payee');
  const [draggingId, setDraggingId] = useState<string | null>(null);

  useEffect(() => () => {
    dragCleanupRef.current?.();
  }, []);

  const mergedLayout = useMemo(() => {
    if (!layout) return {};
    return deepMerge(layout.default_layout_config, layoutConfig);
  }, [layout, layoutConfig]);

  const page = layout?.page;
  const fields = stockType === 'first_hawaiian_4up' ? FHB_FIELDS : REGULAR_FIELDS;
  const sectionBottom = stockType === 'first_hawaiian_4up'
    ? numberAt(page?.preview_slot_bottom)
    : numberAt(page?.check_section_bottom);
  const pageWidth = numberAt(page?.width, 612);
  const pageHeight = numberAt(page?.height, 792);
  const offsetXPoints = Number(offsetX || 0) * POINTS_PER_INCH;
  const offsetYPoints = Number(offsetY || 0) * POINTS_PER_INCH;

  const fieldBoxes = fields.map((spec): FieldBox | null => {
    const config = fieldConfig(mergedLayout, spec);
    if (!config) return null;

    const x = numberAt(config.x);
    const y = numberAt(config.y);
    const width = numberAt(config.width, 120);
    const fontSize = numberAt(config.font_size, 8);
    const height = numberAt(config.height, spec.field === 'payee_address' ? 34 : FIELD_HEIGHT);
    const absoluteX = x + offsetXPoints;
    const absoluteY = sectionBottom + y + offsetYPoints;

    return {
      ...spec,
      x,
      y,
      width,
      height,
      fontSize,
      left: absoluteX,
      top: pageHeight - absoluteY,
    };
  }).filter(Boolean) as FieldBox[];

  const selectedField = fieldBoxes.find((field) => field.id === selectedId) ?? fieldBoxes[0];

  const updateField = (field: FieldBox, changes: LayoutConfig) => {
    onLayoutConfigChange(setNestedField(layoutConfig, field.section, field.field, changes));
  };

  const nudgeSelected = (dx: number, dy: number) => {
    if (!selectedField) return;
    updateField(selectedField, {
      x: formatPoint(selectedField.x + dx),
      y: formatPoint(selectedField.y + dy),
    });
  };

  const nudgeOffset = (dx: number, dy: number) => {
    if (dx !== 0) onOffsetChange('x', formatOffset(Number(offsetX || 0) + dx));
    if (dy !== 0) onOffsetChange('y', formatOffset(Number(offsetY || 0) + dy));
  };

  const resizeSelected = (delta: number) => {
    if (!selectedField) return;
    updateField(selectedField, {
      width: Math.max(24, formatPoint(selectedField.width + delta)),
    });
  };

  const handlePointerDown = (event: ReactPointerEvent<HTMLButtonElement>, field: FieldBox) => {
    if (disabled) return;
    const preview = previewRef.current;
    if (!preview) return;

    event.preventDefault();
    dragCleanupRef.current?.();
    event.currentTarget.setPointerCapture(event.pointerId);
    setSelectedId(field.id);
    setDraggingId(field.id);

    const rect = preview.getBoundingClientRect();
    const scale = rect.width / pageWidth;
    const startX = event.clientX;
    const startY = event.clientY;
    const startFieldX = field.x;
    const startFieldY = field.y;

    const handleMove = (moveEvent: PointerEvent) => {
      const dx = (moveEvent.clientX - startX) / scale;
      const dy = (moveEvent.clientY - startY) / scale;
      updateField(field, {
        x: formatPoint(startFieldX + dx),
        y: formatPoint(startFieldY - dy),
      });
    };

    const cleanup = (clearDragState: boolean) => {
      if (clearDragState) setDraggingId(null);
      window.removeEventListener('pointermove', handleMove);
      window.removeEventListener('pointerup', handleUp);
      dragCleanupRef.current = null;
    };

    const handleUp = () => {
      cleanup(true);
    };

    window.addEventListener('pointermove', handleMove);
    window.addEventListener('pointerup', handleUp);
    dragCleanupRef.current = () => cleanup(false);
  };

  if (!layout) {
    return (
      <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-500">
        Loading visual calibration...
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_300px]">
        <div className="rounded-xl border border-neutral-200 bg-gradient-to-b from-slate-50 to-slate-100 p-4 shadow-inner">
          <div
            ref={previewRef}
            className="relative mx-auto w-full max-w-[640px] overflow-hidden rounded-lg border border-slate-300 bg-white shadow-md"
            style={{ aspectRatio: `${pageWidth} / ${pageHeight}` }}
          >
            {stockType === 'first_hawaiian_4up' ? (
              Array.from({ length: 4 }).map((_, index) => (
                <div
                  key={index}
                  className="absolute left-0 right-0 border-b border-dashed border-neutral-300"
                  style={{
                    top: `${(index / 4) * 100}%`,
                    height: '25%',
                  }}
                >
                  <span className="absolute left-2 top-2 rounded bg-neutral-100 px-1.5 py-0.5 text-[10px] font-semibold text-neutral-500">
                    Check {index + 1}
                  </span>
                </div>
              ))
            ) : (
              <>
                <div className="absolute left-0 right-0 top-1/3 border-t border-dashed border-neutral-300" />
                <div className="absolute left-0 right-0 top-2/3 border-t border-dashed border-neutral-300" />
                <div
                  className="absolute left-0 right-0 bg-blue-50/40"
                  style={{
                    top: `${((pageHeight - sectionBottom - numberAt(page?.section_height)) / pageHeight) * 100}%`,
                    height: `${(numberAt(page?.section_height) / pageHeight) * 100}%`,
                  }}
                />
              </>
            )}

            {fieldBoxes.map((field, index) => {
              const isSelected = selectedField?.id === field.id;
              const isDragging = draggingId === field.id;

              return (
                <button
                  key={field.id}
                  type="button"
                  onPointerDown={(event) => handlePointerDown(event, field)}
                  onClick={() => setSelectedId(field.id)}
                  disabled={disabled}
                  className={cn(
                    'absolute rounded-md border px-1.5 py-0.5 text-left leading-tight transition-[background-color,border-color,box-shadow,transform]',
                    'hover:border-primary-500 hover:bg-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300',
                    isSelected
                      ? 'border-primary-600 bg-white shadow-lg shadow-primary-950/10 ring-2 ring-primary-200'
                      : 'border-slate-300 bg-white/90 shadow-[0_1px_4px_rgba(15,23,42,0.12)]',
                    !disabled && 'cursor-grab',
                    isDragging && 'scale-[1.01] cursor-grabbing shadow-xl shadow-primary-950/15',
                    disabled && 'cursor-not-allowed opacity-60'
                  )}
                  style={{
                    left: `${(field.left / pageWidth) * 100}%`,
                    top: `${(field.top / pageHeight) * 100}%`,
                    width: `${(field.width / pageWidth) * 100}%`,
                    minHeight: `${(field.height / pageHeight) * 100}%`,
                    fontSize: `${Math.max(8, field.fontSize)}px`,
                    textAlign: field.align ?? 'left',
                    zIndex: isDragging ? 50 : isSelected ? 40 : 10 + index,
                  }}
                  aria-label={`Select ${field.label} field`}
                >
                  <span className="block truncate text-[9px] font-semibold uppercase tracking-wide text-primary-700">{field.label}</span>
                  <span className="block overflow-hidden whitespace-pre-line text-neutral-800">{field.sample}</span>
                </button>
              );
            })}
          </div>
        </div>

        <div className="space-y-3">
          <div className="rounded-xl border border-neutral-200 bg-white p-4 shadow-sm">
            <Label className="text-xs uppercase text-neutral-500">Selected Field</Label>
            <p className="mt-1 text-sm font-semibold text-neutral-900">{selectedField?.label ?? 'None'}</p>
            {selectedField && (
              <div className="mt-3 grid grid-cols-2 gap-2 text-xs text-neutral-500">
                <span>X {selectedField.x.toFixed(1)}</span>
                <span>Y {selectedField.y.toFixed(1)}</span>
                <span>Width {selectedField.width.toFixed(1)}</span>
                <span>Font {selectedField.fontSize.toFixed(1)}</span>
              </div>
            )}
          </div>

          <div className="rounded-xl border border-neutral-200 bg-white p-4 shadow-sm">
            <Label className="text-xs uppercase text-neutral-500">Nudge Field</Label>
            <div className="mt-3 grid grid-cols-3 gap-2">
              <span />
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeSelected(0, 1)} disabled={disabled || !selectedField} aria-label="Move field up">
                <ArrowUp className="h-4 w-4" />
              </Button>
              <span />
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeSelected(-1, 0)} disabled={disabled || !selectedField} aria-label="Move field left">
                <ArrowLeft className="h-4 w-4" />
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeSelected(0, -1)} disabled={disabled || !selectedField} aria-label="Move field down">
                <ArrowDown className="h-4 w-4" />
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeSelected(1, 0)} disabled={disabled || !selectedField} aria-label="Move field right">
                <ArrowRight className="h-4 w-4" />
              </Button>
            </div>
            <div className="mt-2 grid grid-cols-2 gap-2">
              <Button type="button" variant="outline" size="sm" onClick={() => resizeSelected(-6)} disabled={disabled || !selectedField}>
                Narrower
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => resizeSelected(6)} disabled={disabled || !selectedField}>
                Wider
              </Button>
            </div>
          </div>

          <div className="rounded-xl border border-neutral-200 bg-white p-4 shadow-sm">
            <Label className="flex items-center gap-1 text-xs uppercase text-neutral-500">
              <Move className="h-3.5 w-3.5" />
              Move Whole Layout
            </Label>
            <div className="mt-3 grid grid-cols-3 gap-2">
              <span />
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeOffset(0, 0.01)} disabled={disabled} aria-label="Move layout up">
                <ArrowUp className="h-4 w-4" />
              </Button>
              <span />
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeOffset(-0.01, 0)} disabled={disabled} aria-label="Move layout left">
                <ArrowLeft className="h-4 w-4" />
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeOffset(0, -0.01)} disabled={disabled} aria-label="Move layout down">
                <ArrowDown className="h-4 w-4" />
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => nudgeOffset(0.01, 0)} disabled={disabled} aria-label="Move layout right">
                <ArrowRight className="h-4 w-4" />
              </Button>
            </div>
            <p className="mt-2 text-xs text-neutral-500">
              X {Number(offsetX || 0).toFixed(3)} in, Y {Number(offsetY || 0).toFixed(3)} in
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
