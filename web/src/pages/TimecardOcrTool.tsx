import { Header } from '@/components/layout/Header';
import { TimecardOcrPanel } from '@/components/payroll/TimecardOcrPanel';

export function TimecardOcrTool() {
  return (
    <div>
      <Header
        title="Timecard OCR"
        description="Upload timecard images or PDFs to extract punch times using GPT. Review and correct as needed."
      />

      <div className="p-6 lg:p-8">
        <TimecardOcrPanel />
      </div>
    </div>
  );
}
