// @vitest-environment jsdom

import { cleanup, render, waitFor } from '@testing-library/react';
import { Activity, ClipboardList } from 'lucide-react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WorkspaceTabs } from './WorkspaceTabs';

const originalScrollIntoView = Element.prototype.scrollIntoView;

describe('WorkspaceTabs', () => {
  afterEach(() => {
    cleanup();
    if (originalScrollIntoView) {
      Element.prototype.scrollIntoView = originalScrollIntoView;
    } else {
      Reflect.deleteProperty(Element.prototype, 'scrollIntoView');
    }
  });

  it('brings the active tab into view for horizontally scrolling mobile tabs', async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;

    render(
      <MemoryRouter initialEntries={['/records/2/activity']}>
        <WorkspaceTabs
          label="Record sections"
          tabs={[
            { id: 'overview', label: 'Overview', href: '/records/2/overview', icon: ClipboardList },
            { id: 'activity', label: 'Activity', href: '/records/2/activity', icon: Activity },
          ]}
        />
      </MemoryRouter>,
    );

    await waitFor(() => expect(scrollIntoView).toHaveBeenCalledWith({ block: 'nearest', inline: 'center' }));
  });
});
