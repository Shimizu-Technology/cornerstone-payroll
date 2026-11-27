import type { RecordCreatorInfo } from '@/services/api';
import { formatGuamDateTime } from '@/lib/utils';

export function RecordCreatorLine({ creator }: { creator?: RecordCreatorInfo | null }) {
  return <p className="mt-1 break-words text-xs text-neutral-500">{creator
    ? <>Created by {creator.name}{creator.role ? ` (${creator.role.replaceAll('_', ' ')})` : ''} · {formatGuamDateTime(creator.created_at)}</>
    : 'Creator not recorded'}</p>;
}
