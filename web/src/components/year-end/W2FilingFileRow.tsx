import { useState } from "react";
import { reportsApi } from "@/services/api";
import { Button } from "@/components/ui/button";

export function W2FilingFileRow({
  companyId,
  year,
  ready,
}: {
  companyId: number;
  year: number;
  ready: boolean;
}) {
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function download(pdf: boolean) {
    setBusy(true);
    setError("");
    try {
      const result = await reportsApi.wageFilingFile(
        year,
        companyId,
        ready ? "final" : "draft",
        pdf,
      );
      const url = URL.createObjectURL(result.blob);
      const link = document.createElement("a");
      link.href = url;
      link.download =
        result.filename ??
        `${companyId}-${year}-${ready ? "FINAL" : "DRAFT"}-${pdf ? "W3SS.pdf" : "EFW2.txt"}`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Download failed.");
    } finally {
      setBusy(false);
    }
  }
  return (
    <section
      className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4"
      aria-label="W-2 filing files"
    >
      <h3 className="font-semibold">W-2 filing files</h3>
      <p className="text-sm text-neutral-700">
        {ready
          ? "Download the EFW2 file for SSA and GuamTax. Keep W-3SS for your records."
          : "Test file — don’t upload as your filing. Mark W-2s ready before downloading a final file."}
      </p>
      {!ready && (
        <label className="flex min-h-11 items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(e) => setConfirmed(e.target.checked)}
          />
          I understand this is a test file for AccuWage.
        </label>
      )}
      <div className="flex flex-wrap gap-2">
        <Button
          disabled={busy || (!ready && !confirmed)}
          onClick={() => void download(false)}
        >
          Download {ready ? "" : "draft "}EFW2
        </Button>
        <Button
          variant="outline"
          disabled={busy || (!ready && !confirmed)}
          onClick={() => void download(true)}
        >
          W-3SS records PDF
        </Button>
      </div>
      <p className="text-xs text-neutral-600">
        Contains full SSNs. Store securely. For your records — do not mail W-3SS
        when you e-file.
      </p>
      {error && (
        <p role="alert" className="text-sm text-danger-700">
          {error}
        </p>
      )}
    </section>
  );
}
