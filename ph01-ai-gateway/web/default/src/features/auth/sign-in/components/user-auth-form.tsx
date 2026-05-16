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

const PH01_PROTOCOL_OPEN_CHECK_MS = 2500
const PH01_STATUS_INITIAL_DELAY_MS = 900
const PH01_STATUS_MAX_POLL_MS = 60_000
const PH01_STATUS_MAX_INTERVAL_MS = 5000

type HttpLikeError = {
  response?: {
    status?: number
    headers?: Record<string, string | number | undefined>
  }
}

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

function nextStatusPollDelay(attempt: number) {
  return Math.min(1500 + attempt * 500, PH01_STATUS_MAX_INTERVAL_MS)
}

function httpStatus(error: unknown) {
  return (error as HttpLikeError | undefined)?.response?.status
}

function retryAfterMs(error: unknown) {
  const headers = (error as HttpLikeError | undefined)?.response?.headers
  const raw = headers?.['retry-after'] ?? headers?.['Retry-After']
  const seconds =
    typeof raw === 'number' ? raw : typeof raw === 'string' ? Number(raw) : 0
  return Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : 0
}

export function UserAuthForm({
  className,
  redirectTo,
  ...props
}: AuthFormProps) {
  const { t } = useTranslation()
  const { status } = useStatus()
  const { handleLoginSuccess } = useAuthRedirect()
  const [challenge, setChallenge] = useState<PH01ChallengeResponse | null>(null)
  const [authorizationText, setAuthorizationText] = useState('')
  const [agreedToLegal, setAgreedToLegal] = useState(false)
  const [isChallengeLoading, setIsChallengeLoading] = useState(false)
  const [isProtocolLoading, setIsProtocolLoading] = useState(false)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [protocolHelp, setProtocolHelp] = useState('')
  const pollTimerRef = useRef<number | null>(null)
  const protocolOpenCheckTimerRef = useRef<number | null>(null)
  const protocolLaunchCleanupRef = useRef<(() => void) | null>(null)
  const protocolWindowLeftRef = useRef(false)
  const pollStartedAtRef = useRef(0)
  const pollAttemptRef = useRef(0)
  const pollChallengeStatusRef = useRef<(challengeId: string) => void>(() => {})
  const legalConsentErrorMessage = t('Please agree to the legal terms first')

  const hasUserAgreement = Boolean(status?.user_agreement_enabled)
  const hasPrivacyPolicy = Boolean(status?.privacy_policy_enabled)
  const requiresLegalConsent = hasUserAgreement || hasPrivacyPolicy
  const legalConsentReady = !requiresLegalConsent || agreedToLegal

  const clearProtocolOpenCheck = useCallback(() => {
    if (protocolOpenCheckTimerRef.current) {
      window.clearTimeout(protocolOpenCheckTimerRef.current)
      protocolOpenCheckTimerRef.current = null
    }
    protocolLaunchCleanupRef.current?.()
    protocolLaunchCleanupRef.current = null
  }, [])

  const stopPolling = useCallback(() => {
    if (pollTimerRef.current) {
      window.clearTimeout(pollTimerRef.current)
      pollTimerRef.current = null
    }
    clearProtocolOpenCheck()
    pollStartedAtRef.current = 0
    pollAttemptRef.current = 0
    setIsProtocolLoading(false)
  }, [clearProtocolOpenCheck])

  const refreshChallenge = useCallback(async () => {
    stopPolling()
    setProtocolHelp('')
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

  const showManualLoginHint = useCallback(
    (message: string) => {
      stopPolling()
      setProtocolHelp(message)
      toast.info(message)
    },
    [stopPolling]
  )

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void refreshChallenge()
    }, 0)
    return () => {
      window.clearTimeout(timer)
      stopPolling()
    }
  }, [refreshChallenge, stopPolling])

  const startProtocolOpenCheck = useCallback(() => {
    clearProtocolOpenCheck()
    protocolWindowLeftRef.current = false
    const markWindowLeft = () => {
      protocolWindowLeftRef.current = true
    }
    const markVisibilityChange = () => {
      if (document.visibilityState === 'hidden') markWindowLeft()
    }
    window.addEventListener('blur', markWindowLeft)
    document.addEventListener('visibilitychange', markVisibilityChange)
    protocolLaunchCleanupRef.current = () => {
      window.removeEventListener('blur', markWindowLeft)
      document.removeEventListener('visibilitychange', markVisibilityChange)
    }
    protocolOpenCheckTimerRef.current = window.setTimeout(() => {
      clearProtocolOpenCheck()
      if (!protocolWindowLeftRef.current) {
        showManualLoginHint(
          t(
            'PH01 client was not opened. Copy the challenge code, authorize it in the client, then paste the login code below.'
          )
        )
      }
    }, PH01_PROTOCOL_OPEN_CHECK_MS)
  }, [clearProtocolOpenCheck, showManualLoginHint, t])

  const pollChallengeStatus = useCallback(
    async (challengeId: string) => {
      if (!pollStartedAtRef.current) {
        pollStartedAtRef.current = Date.now()
      }
      if (Date.now() - pollStartedAtRef.current >= PH01_STATUS_MAX_POLL_MS) {
        showManualLoginHint(
          t(
            'PH01 authorization timed out. Copy the challenge code and paste the login code below.'
          )
        )
        return
      }
      const scheduleNextPoll = (delayMs?: number) => {
        const attempt = pollAttemptRef.current
        pollAttemptRef.current += 1
        const delay = delayMs ?? nextStatusPollDelay(attempt)
        pollTimerRef.current = window.setTimeout(
          () => pollChallengeStatusRef.current(challengeId),
          delay
        )
      }
      try {
        const res = await getPH01ChallengeStatus(challengeId)
        if (res.success && res.data?.id) {
          stopPolling()
          await handleLoginSuccess(res.data, redirectTo)
          toast.success(t('Welcome back!'))
          return
        }
        if (res.success && res.data?.status === 'pending') {
          scheduleNextPoll()
          return
        }
        stopPolling()
        toast.error(res.message || t('Login failed'))
      } catch (error) {
        const status = httpStatus(error)
        if (status === 400 || status === 404) {
          showManualLoginHint(
            t(
              'PH01 login challenge expired. Refresh the challenge or use login code.'
            )
          )
          return
        }
        if (status === 429) {
          scheduleNextPoll(
            Math.max(retryAfterMs(error), PH01_STATUS_MAX_INTERVAL_MS)
          )
          return
        }
        scheduleNextPoll(PH01_STATUS_MAX_INTERVAL_MS)
      }
    },
    [handleLoginSuccess, redirectTo, showManualLoginHint, stopPolling, t]
  )

  useEffect(() => {
    pollChallengeStatusRef.current = pollChallengeStatus
  }, [pollChallengeStatus])

  const handleProtocolLogin = async () => {
    if (!legalConsentReady) {
      toast.error(legalConsentErrorMessage)
      return
    }
    if (!challenge) {
      await refreshChallenge()
      return
    }

    setIsProtocolLoading(true)
    setProtocolHelp(t('Waiting for PH01 client authorization...'))
    pollStartedAtRef.current = Date.now()
    pollAttemptRef.current = 0
    startProtocolOpenCheck()
    window.location.href = challenge.protocol_url
    pollTimerRef.current = window.setTimeout(
      () => pollChallengeStatusRef.current(challenge.challenge_id),
      PH01_STATUS_INITIAL_DELAY_MS
    )
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
    if (!legalConsentReady) {
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
          !legalConsentReady
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
      {protocolHelp ? (
        <p className='text-muted-foreground text-sm'>{protocolHelp}</p>
      ) : null}

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
            isSubmitting || !authorizationText.trim() || !legalConsentReady
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
        checked={legalConsentReady}
        onCheckedChange={setAgreedToLegal}
        className='mt-1'
      />
    </form>
  )
}
