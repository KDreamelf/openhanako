import { Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { ArrowRight, Cable, Network } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { AnimateInView } from '@/components/animate-in-view'

interface CTAProps {
  className?: string
  isAuthenticated?: boolean
}

export function CTA(props: CTAProps) {
  const { t } = useTranslation()

  return (
    <section className='relative z-10 overflow-hidden px-6 py-24 md:py-32'>
      <AnimateInView
        className='mx-auto max-w-5xl rounded-lg border border-blue-200/80 bg-white/95 p-6 shadow-[0_18px_56px_-42px_rgba(29,78,216,0.5)] dark:border-sky-300/12 dark:bg-[#071a33]/94 md:p-10'
        animation='scale-in'
      >
        <div className='grid gap-10 md:grid-cols-[1fr_0.88fr] md:items-center'>
          <div>
            <p className='text-muted-foreground mb-3 text-xs font-medium tracking-widest uppercase'>
              {t('home.cta.kicker')}
            </p>
            <h2 className='text-2xl leading-tight font-bold tracking-normal md:text-4xl'>
              {t('home.cta.titleLine1')}
              <br />
              <span className='text-sky-600 dark:text-sky-300'>
                {t('home.cta.titleLine2')}
              </span>
            </h2>
            <p className='text-muted-foreground/90 mt-5 max-w-2xl text-base leading-8'>
              {t('home.cta.description')}
            </p>
            <div className='mt-8 flex flex-col gap-3 sm:flex-row'>
              <Button className='group rounded-lg' asChild>
                <Link to={props.isAuthenticated ? '/dashboard' : '/sign-in'}>
                  {props.isAuthenticated ? t('Go to Dashboard') : t('Sign in')}
                  <ArrowRight className='ml-1 size-3.5 transition-transform duration-200 group-hover:translate-x-0.5' />
                </Link>
              </Button>
              <Button
                variant='outline'
                className='border-border/50 hover:border-border hover:bg-muted/50 rounded-lg'
                asChild
              >
                <Link to='/pricing'>{t('home.hero.secondaryCta')}</Link>
              </Button>
            </div>
          </div>

          <div className='grid gap-3'>
            <BridgeDiagram />
            <ComparisonTile
              icon={<Cable className='size-5' strokeWidth={1.6} />}
              title={t('home.cta.internetTitle')}
              desc={t('home.cta.internetDesc')}
            />
            <ComparisonTile
              icon={<Network className='size-5' strokeWidth={1.6} />}
              title={t('home.cta.networkTitle')}
              desc={t('home.cta.networkDesc')}
              active
            />
          </div>
        </div>
      </AnimateInView>
    </section>
  )
}

function BridgeDiagram() {
  const { t } = useTranslation()

  return (
    <div className='overflow-hidden rounded-lg border border-blue-200/70 bg-sky-500/[0.04] p-4 dark:border-sky-300/10'>
      <div className='mb-3 flex items-center justify-between gap-3'>
        <span className='text-xs font-medium text-muted-foreground'>
          {t('home.cta.bridgeLabel')}
        </span>
        <span className='rounded-md bg-sky-500/10 px-2 py-1 text-[11px] font-medium text-sky-700 dark:text-sky-300'>
          {t('home.cta.bridgeStatus')}
        </span>
      </div>
      <div className='relative h-36'>
        <svg
          aria-hidden='true'
          className='absolute inset-0 h-full w-full text-sky-500/55 dark:text-sky-300/45'
          viewBox='0 0 420 144'
          preserveAspectRatio='none'
        >
          <path
            className='ph01-bridge-thread'
            d='M34 48 C98 48, 140 48, 190 72 C238 96, 286 96, 386 96'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
          />
          <path
            className='ph01-bridge-active'
            d='M34 48 C98 48, 140 48, 190 72 C238 96, 286 96, 386 96'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='3'
          />
          <path
            className='ph01-bridge-thread'
            d='M34 96 C96 96, 132 96, 184 78 C236 60, 294 48, 386 48'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
            strokeOpacity='0.34'
          />
          <circle className='ph01-bridge-packet' r='4.5' fill='currentColor' />
          <circle
            className='ph01-bridge-packet ph01-bridge-packet-late'
            r='4'
            fill='currentColor'
          />
        </svg>
        <div className='ph01-bridge-side absolute top-5 left-1 rounded-lg border border-blue-200/70 bg-background/90 px-3 py-2 dark:border-sky-300/12 dark:bg-[#071a33]'>
          <p className='text-xs font-semibold'>{t('home.cta.internetTitle')}</p>
          <p className='text-muted-foreground mt-1 text-[11px]'>
            {t('home.cta.bridgeLeft')}
          </p>
        </div>
        <div className='ph01-bridge-gate absolute top-1/2 left-1/2 flex size-20 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border border-sky-400/40 bg-sky-500/10 text-center'>
          <span className='text-xs leading-4 font-semibold text-sky-700 dark:text-sky-200'>
            {t('home.cta.bridgeGate')}
          </span>
        </div>
        <div className='ph01-bridge-side ph01-bridge-side-active absolute right-1 bottom-5 rounded-lg border border-sky-400/45 bg-sky-500/10 px-3 py-2'>
          <p className='text-xs font-semibold'>{t('home.cta.networkTitle')}</p>
          <p className='text-muted-foreground mt-1 text-[11px]'>
            {t('home.cta.bridgeRight')}
          </p>
        </div>
      </div>
    </div>
  )
}

function ComparisonTile(props: {
  icon: ReactNode
  title: string
  desc: string
  active?: boolean
}) {
  return (
    <div
      className={
        props.active
          ? 'rounded-lg border border-sky-400/45 bg-sky-500/10 p-5'
          : 'rounded-lg border border-blue-200/70 bg-background/70 p-5 dark:border-sky-300/10'
      }
    >
      <div className='flex items-center gap-3'>
        <div className='text-sky-700 dark:text-sky-300'>{props.icon}</div>
        <h3 className='font-semibold'>{props.title}</h3>
      </div>
      <p className='text-muted-foreground mt-3 text-sm leading-7'>
        {props.desc}
      </p>
    </div>
  )
}
