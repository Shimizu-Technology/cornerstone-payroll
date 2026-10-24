import { useEffect, type ReactElement } from 'react'
import { isStaging, stagingCodeSha, stagingLabel, stagingSnapshot } from '../lib/staging'
import './StagingContext.css'

export function StagingContext(): ReactElement | null {
  useEffect(() => {
    if (!isStaging) return
    document.documentElement.dataset.staging = 'true'
    const prefixTitle = (): void => {
      if (!document.title.startsWith('[STAGING]')) document.title = `[STAGING] ${document.title}`
    }
    prefixTitle()
    const observer = new MutationObserver(prefixTitle)
    observer.observe(document.querySelector('title')!, { childList: true, subtree: true })
    const favicon = document.createElement('link')
    favicon.rel = 'icon'
    favicon.type = 'image/svg+xml'
    favicon.href = '/staging-favicon.svg'
    document.head.appendChild(favicon)
    // Cloned contact links must not open a real communication application.
    const containContactLink = (event: MouseEvent): void => {
      const link = (event.target as Element).closest?.('a')
      if (link && /^(mailto:|tel:|sms:|https:\/\/(wa\.me|api\.whatsapp\.com)\/)/i.test(link.href)) {
        event.preventDefault()
        event.stopPropagation()
      }
    }
    document.addEventListener('click', containContactLink, true)
    document.addEventListener('auxclick', containContactLink, true)
    return () => {
      observer.disconnect()
      favicon.remove()
      delete document.documentElement.dataset.staging
      document.removeEventListener('click', containContactLink, true)
      document.removeEventListener('auxclick', containContactLink, true)
    }
  }, [])

  if (!isStaging) return null
  return (
    <aside className="staging-context" aria-label="Staging environment">
      <strong>STAGING</strong>
      <span>{stagingLabel}</span>
      <span className="staging-context-meta">Snapshot: {stagingSnapshot} · Code: {stagingCodeSha.slice(0, 12)}</span>
      <span className="staging-context-note">Test data changes stay here.</span>
    </aside>
  )
}
