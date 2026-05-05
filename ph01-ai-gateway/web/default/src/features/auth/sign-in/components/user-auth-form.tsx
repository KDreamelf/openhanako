import { useCallback, useEffect, useRef, useState } from 'react'
import { Copy, KeyRound, Loader2, LogIn, RefreshCw } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { useStatus } from '@/hooks/use-status'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  completePH01Login,
  createPH01Challenge,
  getPH01ChallengeStatus,
} from '@/features/auth/api'
import { LegalConsent } from '@/features/auth/components/legal-consent'
import { useAuthRedirect } from '@/features/auth/hooks/use-auth-redirect'
import type {
  AuthFormProps,
  PH01ChallengeResponse,
  PH01SignedLoginRequest,
} from '@/features/auth/types'

function parseSignedLogin(raw: string): PH01SignedLoginRequest | null {
  try {
    const parsed = JSON.parse(raw.trim()) as PH01SignedLoginRequest
    if (!Number.isFinite(parsed.user_id) || parsed.user_id <= 0) return null
    if (!parsed.nonce) return null
    if (!parsed.signature && !parsed.signature_hex) return null
    return parsed
  } catch {
    return null
  }
}

export function UserAuthForm({
  className,
  redirectTo,
  ...props
}: AuthFormProps) {
  const { t } = useTranslation()
  const { status } = useStatus()
  const { handleLoginSuccess } = useAuthRedirect()
  const [challenge, setChallenge] = useState<PH01ChallengeResponse | null>(
    null
  )
  const [authorizationText, setAuthorizationText] = useState('')
  const [agreedToLegal, setAgreedToLegal] = useState(false)
  const [isChallengeLoading, setIsChallengeLoading] = useState(false)
  const [isProtocolLoading, setIsProtocolLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const pollTimerRef = useRef<number | null>(null)
  const legalConsentErrorMessage = t('Please agree to the legal terms first')

  const hasUserAgreement = Boolean(status?.user_agreement_enabled)
  const hasPrivacyPolicy = Boolean(status?.privacy_policy_enabled)
  const requiresLegalConsent = hasUserAgreement || hasPrivacyPolicy

  useEffect(() => {
    setAgreedToLegal(!requiresLegalConsent)
  }, [requiresLegalConsent])

  const stopPolling = useCallback(() => {
    if (pollTimerRef.current) {
      window.clearTimeout(pollTimerRef.current)
      pollTimerRef.current = null
    }
    setIsProtocolLoading(false)
  }, [])

  const refreshChallenge = useCallback(async () => {
    stopPolling()
    setIsChallengeLoading(true)
    try {
      const res = await createPH01Challenge()
      if (res.success && res.data) {
        setChallenge(res.data)
      } else {
        toast.error(res.message || t('Failed to create login challenge'))
      }
    } catch {
      toast.error(t('Failed to create login challenge'))
    } finally {
      setIsChallengeLoading(false)
    }
  }, [stopPolling, t])

  useEffect(() => {
    refreshChallenge()
    return stopPolling
  }, [refreshChallenge, stopPolling])

  const pollChallengeStatus = useCallback(
    async (challengeId: string) => {
      try {
        const res = await getPH01ChallengeStatus(challengeId)
        if (res.success && res.data?.id) {
          stopPolling()
          await handleLoginSuccess(res.data, redirectTo)
          toast.success(t('Welcome back!'))
          return
        }
        if (res.success && res.data?.status === 'pending') {
          pollTimerRef.current = window.setTimeout(
            () => pollChallengeStatus(challengeId),
            1500
          )
          return
        }
        stopPolling()
        toast.error(res.message || t('Login failed'))
      } catch {
        pollTimerRef.current = window.setTimeout(
          () => pollChallengeStatus(challengeId),
          1500
        )
      }
    },
    [handleLoginSuccess, redirectTo, stopPolling, t]
  )

  const handleProtocolLogin = async () => {
    if (requiresLegalConsent && !agreedToLegal) {
      toast.error(legalConsentErrorMessage)
      return
    }
    if (!challenge) {
      await refreshChallenge()
      return
    }

    setIsProtocolLoading(true)
    window.location.href = challenge.protocol_url
    pollChallengeStatus(challenge.challenge_id)
  }

  const handleCopyChallenge = async () => {
    if (!challenge?.challenge) return
    try {
      await navigator.clipboard.writeText(challenge.challenge)
      toast.success(t('Copied'))
    } catch {
      toast.error(t('Copy failed'))
    }
  }

  const handleSubmitAuthorization = async () => {
    if (requiresLegalConsent && !agreedToLegal) {
      toast.error(legalConsentErrorMessage)
      return
    }
    const signed = parseSignedLogin(authorizationText)
    if (!signed) {
      toast.error(t('Invalid login code'))
      return
    }

    setIsSubmitting(true)
    try {
      const res = await completePH01Login(signed)
      if (res.success) {
        await handleLoginSuccess(res.data as { id?: number } | null, redirectTo)
        toast.success(t('Welcome back!'))
      } else {
        toast.error(res.message || t('Login failed'))
      }
    } catch {
      toast.error(t('Login failed'))
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <form
      className={cn('grid gap-4', className)}
      {...props}
      onSubmit={(event) => event.preventDefault()}
    >
      <div className='grid gap-2'>
        <Label>{t('PH01 Login Challenge')}</Label>
        <Textarea
          readOnly
          value={challenge?.challenge ?? ''}
          className='min-h-24 resize-none font-mono text-xs'
        />
        <div className='grid grid-cols-2 gap-2'>
          <Button
            type='button'
            variant='outline'
            onClick={refreshChallenge}
            disabled={isChallengeLoading}
            className='justify-center gap-2'
          >
            {isChallengeLoading ? (
              <Loader2 className='h-4 w-4 animate-spin' />
            ) : (
              <RefreshCw className='h-4 w-4' />
            )}
            {t('Refresh')}
          </Button>
          <Button
            type='button'
            variant='outline'
            onClick={handleCopyChallenge}
            disabled={!challenge}
            className='justify-center gap-2'
          >
            <Copy className='h-4 w-4' />
            {t('Copy')}
          </Button>
        </div>
      </div>

      <Button
        type='button'
        onClick={handleProtocolLogin}
        disabled={
          isProtocolLoading ||
          isChallengeLoading ||
          !challenge ||
          (requiresLegalConsent && !agreedToLegal)
        }
        className='h-11 w-full justify-center gap-2'
      >
        {isProtocolLoading ? (
          <Loader2 className='h-4 w-4 animate-spin' />
        ) : (
          <KeyRound className='h-4 w-4' />
        )}
        {t('Authorize with PH01 Client')}
      </Button>

      <div className='grid gap-2'>
        <Label htmlFor='ph01-login-code'>{t('Login Code')}</Label>
        <Textarea
          id='ph01-login-code'
          value={authorizationText}
          onChange={(event) => setAuthorizationText(event.target.value)}
          className='min-h-28 resize-none font-mono text-xs'
        />
        <Button
          type='button'
          variant='secondary'
          onClick={handleSubmitAuthorization}
          disabled={
            isSubmitting ||
            !authorizationText.trim() ||
            (requiresLegalConsent && !agreedToLegal)
          }
          className='w-full justify-center gap-2'
        >
          {isSubmitting ? (
            <Loader2 className='h-4 w-4 animate-spin' />
          ) : (
            <LogIn className='h-4 w-4' />
          )}
          {t('Sign in')}
        </Button>
      </div>

      <LegalConsent
        status={status}
        checked={agreedToLegal}
        onCheckedChange={setAgreedToLegal}
        className='mt-1'
      />
    </form>
  )
}
