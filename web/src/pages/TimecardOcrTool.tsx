import { Header } from '@/components/layout/Header';
import { TimecardOcrPanel } from '@/components/payroll/TimecardOcrPanel';

export function TimecardOcrTool() {
  return (
    <div>
      <Header
        title="Timecard OCR"
        description="Upload timecard images or PDFs. We'll read the punch times for you to review and correct."
      />

      <div className="p-6 lg:p-8">
        <TimecardOcrPanel />
      </div>
    </div>
  );
}
