import {
  BadgeCheck,
  FileSearch,
  Handshake,
  Network,
  ShieldCheck,
} from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { AnimateInView } from '@/components/animate-in-view'

export function HowItWorks() {
  const { t } = useTranslation()

  const steps = [
    {
      num: '01',
      title: t('home.network.step1.title'),
      desc: t('home.network.step1.desc'),
      icon: <Handshake className='size-5' strokeWidth={1.6} />,
    },
    {
      num: '02',
      title: t('home.network.step2.title'),
      desc: t('home.network.step2.desc'),
      icon: <ShieldCheck className='size-5' strokeWidth={1.6} />,
    },
    {
      num: '03',
      title: t('home.network.step3.title'),
      desc: t('home.network.step3.desc'),
      icon: <Network className='size-5' strokeWidth={1.6} />,
    },
    {
      num: '04',
      title: t('home.network.step4.title'),
      desc: t('home.network.step4.desc'),
      icon: <BadgeCheck className='size-5' strokeWidth={1.6} />,
    },
  ]

  return (
    <section
      id='experience-network'
      className='border-border/40 relative z-10 border-t px-6 py-24 md:py-32'
    >
      <div className='mx-auto max-w-6xl'>
        <div className='grid gap-14 lg:grid-cols-[0.9fr_1.1fr] lg:items-start'>
          <AnimateInView>
            <p className='text-muted-foreground mb-3 text-xs font-medium tracking-widest uppercase'>
              {t('home.network.kicker')}
            </p>
            <h2 className='max-w-xl text-2xl leading-tight font-bold tracking-normal md:text-4xl'>
              {t('home.network.title')}
            </h2>
            <p className='text-muted-foreground mt-5 max-w-xl text-base leading-8'>
              {t('home.network.description')}
            </p>
            <div className='mt-8 rounded-lg border border-blue-200/70 bg-sky-500/5 p-5 dark:border-sky-300/12 dark:bg-sky-300/5'>
              <div className='mb-3 flex items-center gap-3'>
                <FileSearch
                  className='size-5 text-sky-700 dark:text-sky-300'
                  strokeWidth={1.6}
                />
                <h3 className='font-semibold'>{t('home.network.equalTitle')}</h3>
              </div>
              <p className='text-muted-foreground text-sm leading-7'>
                {t('home.network.equalDesc')}
              </p>
            </div>
          </AnimateInView>

          <div className='relative'>
            <AnimateInView
              animation='fade-left'
              className='mb-4 rounded-lg border border-blue-200/70 bg-background/95 p-5 dark:border-sky-300/12 dark:bg-[#071a33]/92'
            >
              <ExperienceNetworkMap />
            </AnimateInView>
            <div className='grid gap-4'>
              {steps.map((step, index) => (
                <AnimateInView
                  key={step.num}
                  delay={index * 120}
                  animation='fade-left'
                  className='relative rounded-lg border border-blue-200/70 bg-background/95 p-5 dark:border-sky-300/12 dark:bg-[#071a33]/92'
                >
                  <div className='flex gap-4'>
                    <div
                      className='relative z-10 flex size-12 shrink-0 items-center justify-center rounded-lg border border-sky-400/35 bg-sky-500/10 text-sky-700 dark:text-sky-300'
                    >
                      {step.icon}
                    </div>
                    <div>
                      <p className='font-mono text-xs text-sky-700 dark:text-sky-300'>
                        {step.num}
                      </p>
                      <h3 className='mt-1 text-base font-semibold'>
                        {step.title}
                      </h3>
                      <p className='text-muted-foreground mt-2 text-sm leading-7'>
                        {step.desc}
                      </p>
                    </div>
                  </div>
                </AnimateInView>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

function ExperienceNetworkMap() {
  const { t } = useTranslation()

  return (
    <div>
      <div className='mb-4 flex items-center justify-between gap-3'>
        <p className='text-sm font-semibold'>{t('home.network.map.title')}</p>
        <span className='rounded-md bg-cyan-500/10 px-2 py-1 text-[11px] font-medium text-cyan-700 dark:text-cyan-300'>
          {t('home.network.map.status')}
        </span>
      </div>
      <div className='relative min-h-[280px] overflow-hidden rounded-lg border border-blue-200/60 bg-sky-500/[0.03] p-4 dark:border-sky-300/10'>
        <svg
          aria-hidden='true'
          className='absolute inset-0 h-full w-full text-sky-500/52 dark:text-sky-300/44'
          viewBox='0 0 560 280'
          preserveAspectRatio='none'
        >
          <path
            className='ph01-network-orbit'
            d='M78 142 C126 54, 272 36, 394 68 C490 94, 502 204, 410 232 C290 268, 122 230, 78 142'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
          />
          <path
            className='ph01-network-active'
            d='M78 142 C126 54, 272 36, 394 68 C490 94, 502 204, 410 232 C290 268, 122 230, 78 142'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='3'
          />
          <path
            className='ph01-network-feedback'
            d='M412 228 C354 184, 314 158, 280 140 C244 122, 198 118, 150 132'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='2'
          />
          <circle className='ph01-network-packet' r='5' fill='currentColor' />
          <circle
            className='ph01-network-packet ph01-network-packet-late'
            r='4'
            fill='currentColor'
          />
        </svg>

        <div className='ph01-network-node ph01-network-node-user absolute top-[112px] left-4'>
          <p>{t('home.network.map.consent')}</p>
        </div>
        <div className='ph01-network-node ph01-network-node-review absolute top-8 left-1/2 -translate-x-1/2'>
          <p>{t('home.network.map.review')}</p>
        </div>
        <div className='ph01-network-node ph01-network-node-flow absolute top-[112px] right-4'>
          <p>{t('home.network.map.flow')}</p>
        </div>
        <div className='ph01-network-node ph01-network-node-feedback absolute bottom-8 left-1/2 -translate-x-1/2'>
          <p>{t('home.network.map.feedback')}</p>
        </div>
        <div className='ph01-network-core absolute top-1/2 left-1/2 flex size-28 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border border-sky-400/40 bg-sky-500/10 text-center shadow-[0_0_28px_rgba(14,165,233,0.12)]'>
          <div>
            <p className='text-xs font-medium text-sky-700 dark:text-sky-200'>
              {t('home.network.map.coreTop')}
            </p>
            <p className='mt-1 text-sm font-bold'>
              {t('home.network.map.coreBottom')}
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
