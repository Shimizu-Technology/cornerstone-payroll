export function twoPagePdf(): Buffer {
  const shapes = ['1 0 0 rg 20 20 160 160 re f', '0 0 1 rg 20 20 160 160 re f'];
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>',
    `<< /Length ${shapes[0].length} >>\nstream\n${shapes[0]}\nendstream`,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 6 0 R >>',
    `<< /Length ${shapes[1].length} >>\nstream\n${shapes[1]}\nendstream`,
  ];
  let contents = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(contents));
    contents += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(contents);
  contents += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  offsets.slice(1).forEach((offset) => { contents += `${String(offset).padStart(10, '0')} 00000 n \n`; });
  contents += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(contents);
}

