import { api } from '@/lib/api'
import type {
  LoginPayload,
  LoginResponse,
  Login2FAResponse,
  TwoFAPayload,
  ApiResponse,
  PH01ChallengeResponse,
  PH01SignedLoginRequest,
} from './types'

// ============================================================================
// Authentication APIs
// ============================================================================

// ----------------------------------------------------------------------------
// Login & Logout
// ----------------------------------------------------------------------------

// User login with username and password
export async function login(payload: LoginPayload) {
  const turnstile = payload.turnstile ?? ''
  const res = await api.post<LoginResponse>(
    `/api/user/login?turnstile=${turnstile}`,
    {
      username: payload.username,
      password: payload.password,
    }
  )
  return res.data
}

// Two-factor authentication login
export async function login2fa(payload: TwoFAPayload) {
  const res = await api.post<Login2FAResponse>('/api/user/login/2fa', payload)
  return res.data
}

// User logout
export async function logout(): Promise<ApiResponse> {
  const res = await api.get('/api/user/logout')
  return res.data
}

export async function createPH01Challenge(): Promise<
  ApiResponse & { data?: PH01ChallengeResponse }
> {
  const res = await api.get('/api/ph01/auth/challenge', {
    disableDuplicate: true,
  } as Record<string, unknown>)
  return res.data
}

export async function completePH01Login(
  payload: PH01SignedLoginRequest
): Promise<LoginResponse> {
  const res = await api.post('/api/ph01/auth/login', payload)
  return res.data
}

export async function getPH01ChallengeStatus(
  challengeId: string
): Promise<LoginResponse & { data?: { status?: string; id?: number } }> {
  const res = await api.get(`/api/ph01/auth/challenge/${challengeId}/status`, {
    disableDuplicate: true,
    skipBusinessError: true,
  } as Record<string, unknown>)
  return res.data
}

// ----------------------------------------------------------------------------
// Password Management
// ----------------------------------------------------------------------------

// Send password reset email
export async function sendPasswordResetEmail(
  email: string,
  turnstile?: string
): Promise<ApiResponse> {
  const res = await api.get('/api/reset_password', {
    params: { email, turnstile },
  })
  return res.data
}

// ----------------------------------------------------------------------------
// OAuth
// ----------------------------------------------------------------------------

// Start GitHub OAuth flow
export async function githubOAuthStart(clientId: string, state: string) {
  const url = `https://github.com/login/oauth/authorize?client_id=${clientId}&state=${state}&scope=user:email`
  window.open(url)
}

// Get OAuth state for CSRF protection
export async function getOAuthState(): Promise<string> {
  const aff =
    typeof window !== 'undefined' ? (localStorage.getItem('aff') ?? '') : ''
  const res = await api.get('/api/oauth/state', { params: { aff } })
  if (res.data?.success) return res.data.data
  return ''
}

// WeChat login by authorization code
export async function wechatLoginByCode(code: string): Promise<ApiResponse> {
  const res = await api.get('/api/oauth/wechat', { params: { code } })
  return res.data
}

// Send email verification code
export async function sendEmailVerification(
  email: string,
  turnstile?: string
): Promise<ApiResponse> {
  const res = await api.get('/api/verification', {
    params: { email, turnstile },
  })
  return res.data
}

// Bind email to OAuth account
export async function bindEmail(
  email: string,
  code: string
): Promise<ApiResponse> {
  const res = await api.post('/api/oauth/email/bind', {
    email,
    code,
  })
  return res.data
}
