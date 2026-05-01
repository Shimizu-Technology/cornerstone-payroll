export interface VoucherLineItemForm {
  id?: number;
  description: string;
  reference_number: string;
  service_period: string;
  amount: string;
}

export interface VoucherLineItemPayload {
  id?: number;
  description: string;
  reference_number: string | null;
  service_period: string | null;
  amount: number;
  position: number;
}

export function normalizeVoucherLineItems(items: VoucherLineItemForm[]): VoucherLineItemPayload[] {
  return items
    .map((item, index) => ({
      id: item.id,
      description: item.description.trim(),
      reference_number: item.reference_number.trim() || null,
      service_period: item.service_period.trim() || null,
      amount: Number(item.amount || 0),
      position: index,
    }))
    .filter(item => item.amount > 0)
    .map(item => ({
      ...item,
      description: item.description || 'Payment detail',
    }));
}
