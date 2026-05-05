import { Link } from '@tanstack/react-router'
import { ArrowRight, Network } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'

interface HeroProps {
  className?: string
  isAuthenticated?: boolean
}

export function Hero(props: HeroProps) {
  const { t } = useTranslation()
  const modules = [
    t('home.hero.module.subAgent'),
    t('home.hero.module.mainBrain'),
    t('home.hero.module.gateway'),
    t('home.hero.module.network'),
  ]

  return (
    <section
      className={cn(
        'relative z-10 overflow-hidden px-6 pt-28 pb-16 md:pt-36 md:pb-24',
        props.className
      )}
    >
      <div
        aria-hidden
        className='absolute inset-0 -z-10 bg-[linear-gradient(to_right,var(--border)_1px,transparent_1px),linear-gradient(to_bottom,var(--border)_1px,transparent_1px)] [mask-image:linear-gradient(to_bottom,black_0%,transparent_86%)] bg-[size:4rem_4rem] opacity-[0.10]'
      />

      <div className='mx-auto grid max-w-6xl items-center gap-14 md:grid-cols-[minmax(0,1.12fr)_minmax(360px,0.88fr)] md:gap-16'>
        <div>
          <div
            className='landing-animate-fade-up border-border/50 bg-background/90 text-muted-foreground inline-flex items-center gap-2 rounded-lg border px-3 py-1.5 text-sm'
            style={{ animationDelay: '0ms' }}
          >
            <Network className='size-4 text-sky-500' strokeWidth={1.7} />
            <span>{t('home.hero.kicker')}</span>
          </div>
          <h1
            className='landing-animate-fade-up mt-6 max-w-3xl text-[clamp(2.3rem,5.8vw,4.1rem)] leading-[1.08] font-bold tracking-normal'
            style={{ animationDelay: '80ms' }}
          >
            {t('home.hero.titleLine1')}
            <br />
            <span className='text-sky-600 dark:text-sky-300'>
              {t('home.hero.titleLine2')}
            </span>
          </h1>
          <p
            className='landing-animate-fade-up text-muted-foreground/90 mt-6 max-w-2xl text-base leading-8 opacity-0 md:text-lg'
            style={{ animationDelay: '160ms' }}
          >
            {t('home.hero.description')}
          </p>
          <div
            className='landing-animate-fade-up mt-6 flex max-w-2xl flex-wrap gap-2 opacity-0'
            style={{ animationDelay: '210ms' }}
          >
            {modules.map((item) => (
              <span
                key={item}
                className='rounded-lg border border-sky-200/70 bg-sky-500/5 px-3 py-1.5 text-xs font-medium text-sky-800 dark:border-sky-300/15 dark:bg-sky-300/5 dark:text-sky-200'
              >
                {item}
              </span>
            ))}
          </div>
          <div
            className='landing-animate-fade-up mt-8 flex flex-col gap-3 opacity-0 sm:flex-row'
            style={{ animationDelay: '280ms' }}
          >
            {props.isAuthenticated ? (
              <Button className='group rounded-lg' asChild>
                <Link to='/dashboard'>
                  {t('Go to Dashboard')}
                  <ArrowRight className='ml-1 size-3.5 transition-transform duration-200 group-hover:translate-x-0.5' />
                </Link>
              </Button>
            ) : (
              <>
                <Button className='group rounded-lg' asChild>
                  <Link to='/sign-in'>
                    {t('Sign in')}
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
              </>
            )}
          </div>
        </div>

        <div
          className='landing-animate-fade-left opacity-0'
          style={{ animationDelay: '260ms' }}
        >
          <ExperienceRelayDemo />
        </div>
      </div>
    </section>
  )
}

function ExperienceRelayDemo() {
  const { t } = useTranslation()

  const nodes = [
    {
      id: 'context',
      title: t('home.hero.demo.contextTitle'),
      desc: t('home.hero.demo.contextDesc'),
      step: '01',
      className: 'left-5 top-24',
    },
    {
      id: 'judgement',
      title: t('home.hero.demo.judgementTitle'),
      desc: t('home.hero.demo.judgementDesc'),
      step: '02',
      className: 'right-5 top-32',
    },
    {
      id: 'verification',
      title: t('home.hero.demo.verificationTitle'),
      desc: t('home.hero.demo.verificationDesc'),
      step: '03',
      className: 'left-8 bottom-16',
    },
    {
      id: 'reuse',
      title: t('home.hero.demo.reuseTitle'),
      desc: t('home.hero.demo.reuseDesc'),
      step: '04',
      className: 'right-8 bottom-8',
    },
  ]

  return (
    <div className='relative mx-auto h-[520px] max-w-[520px] overflow-hidden rounded-lg border border-blue-200/70 bg-white/95 shadow-[0_18px_54px_-36px_rgba(29,78,216,0.48)] dark:border-sky-300/15 dark:bg-[#071a33] dark:shadow-[0_18px_60px_-38px_rgba(56,189,248,0.34)]'>
      <div
        aria-hidden
        className='absolute inset-0 bg-[linear-gradient(90deg,rgba(37,99,235,0.08)_1px,transparent_1px),linear-gradient(0deg,rgba(37,99,235,0.08)_1px,transparent_1px)] bg-[size:42px_42px] dark:bg-[linear-gradient(90deg,rgba(125,211,252,0.08)_1px,transparent_1px),linear-gradient(0deg,rgba(125,211,252,0.08)_1px,transparent_1px)]'
      />
      <div className='relative z-10 flex items-center justify-between border-b border-blue-200/70 px-5 py-4 dark:border-sky-300/10'>
        <div>
          <p className='text-muted-foreground text-xs font-medium tracking-widest uppercase'>
            {t('home.hero.demo.eyebrow')}
          </p>
          <p className='mt-1 text-sm font-semibold'>
            {t('home.hero.demo.title')}
          </p>
        </div>
        <span className='rounded-md bg-cyan-500/10 px-2 py-1 text-xs font-medium text-cyan-700 dark:text-cyan-300'>
          {t('home.hero.demo.status')}
        </span>
      </div>
      <svg
        aria-hidden='true'
        className='absolute inset-0 h-full w-full text-sky-500/55 dark:text-sky-300/45'
        viewBox='0 0 520 520'
      >
        <defs>
          <radialGradient id='ph01HeroCore' cx='50%' cy='50%' r='60%'>
            <stop offset='0%' stopColor='currentColor' stopOpacity='0.24' />
            <stop offset='70%' stopColor='currentColor' stopOpacity='0.07' />
            <stop offset='100%' stopColor='currentColor' stopOpacity='0' />
          </radialGradient>
        </defs>
        <path
          className='ph01-hero-thread'
          d='M110 145 C 170 96, 284 108, 380 166 C 440 206, 440 306, 380 352 C 306 408, 178 410, 110 340 C 70 298, 74 190, 110 145'
          fill='none'
          stroke='currentColor'
          strokeWidth='1'
          strokeOpacity='0.26'
        />
        <path
          className='ph01-hero-thread ph01-hero-thread-soft'
          d='M110 145 C 164 205, 214 214, 260 260 C 304 304, 332 332, 380 352'
          fill='none'
          stroke='currentColor'
          strokeWidth='1'
        />
        <path
          className='ph01-hero-trace'
          d='M110 145 C 170 96, 284 108, 380 166 C 440 206, 440 306, 380 352 C 306 408, 178 410, 110 340 C 70 298, 74 190, 110 145'
          fill='none'
          stroke='currentColor'
          strokeLinecap='round'
          strokeWidth='2.5'
        />
        <circle cx='260' cy='260' r='96' fill='url(#ph01HeroCore)' />
        <circle
          className='ph01-hero-core-ring'
          cx='260'
          cy='260'
          r='72'
          fill='none'
          stroke='currentColor'
          strokeWidth='1'
          strokeOpacity='0.28'
        />
        <circle className='ph01-hero-packet' r='5' fill='currentColor' />
        <circle
          className='ph01-hero-packet ph01-hero-packet-late'
          r='4'
          fill='currentColor'
          opacity='0.7'
        />
      </svg>
      <div className='absolute inset-0 z-10'>
        <div className='ph01-hero-core absolute top-[214px] left-1/2 flex size-28 -translate-x-1/2 items-center justify-center rounded-full border border-sky-400/40 bg-sky-500/10 text-center shadow-[0_0_28px_rgba(14,165,233,0.14)]'>
          <div>
            <p className='text-xs font-medium text-sky-700 dark:text-sky-200'>
              {t('home.hero.demo.centerTop')}
            </p>
            <p className='mt-1 text-sm font-bold text-sky-950 dark:text-white'>
              {t('home.hero.demo.centerBottom')}
            </p>
          </div>
        </div>
        {nodes.map((node) => (
          <div
            key={node.id}
            className={cn(
              'ph01-sequence-card absolute w-[190px] rounded-lg border border-blue-200/80 bg-white/95 p-4 shadow-[0_10px_28px_-24px_rgba(29,78,216,0.38)] dark:border-sky-300/15 dark:bg-[#0a203d]',
              node.className
            )}
            style={{
              animationDelay: `${nodes.findIndex((item) => item.id === node.id) * 1150}ms`,
            }}
          >
            <div className='mb-2 flex items-center justify-between gap-3'>
              <p className='text-sm font-semibold'>{node.title}</p>
              <span className='font-mono text-[11px] text-sky-700 dark:text-sky-300'>
                {node.step}
              </span>
            </div>
            <p className='text-muted-foreground mt-2 text-xs leading-5'>
              {node.desc}
            </p>
          </div>
        ))}
      </div>
    </div>
  )
}
