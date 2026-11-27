import { Select } from '@/components/ui/select';

export function TippedOccupationCodeSelect({ codes, value, onChange }: {
  codes: Record<string, string>;
  value: string;
  onChange: (code: string) => void;
}) {
  return (
    <Select label="Treasury occupation code" placeholder="Choose a code" required value={value}
      onChange={(event) => onChange(event.target.value)}
      options={Object.entries(codes).sort(([a], [b]) => a.localeCompare(b)).map(([code, name]) => ({
        value: code, label: `${code} · ${name}`,
      }))} />
  );
}
