// ============================================================================
// Affiliate Functions
// ============================================================================

/**
 * Generate gateway entry link.
 */
export function generateAffiliateLink(affCode: string): string {
  if (typeof window === 'undefined') return ''
  return affCode ? `${window.location.origin}/sign-in` : ''
}
