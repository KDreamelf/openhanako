import { BookOpenCheck, CircleHelp, RadioTower } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { AnimateInView } from '@/components/animate-in-view'

interface StatsProps {
  className?: string
}

export function Stats(props: StatsProps) {
  const { t } = useTranslation()

  const reasons = [
    {
      icon: <RadioTower className='size-5' strokeWidth={1.6} />,
      title: t('home.gap.reason1.title'),
      desc: t('home.gap.reason1.desc'),
    },
    {
      icon: <BookOpenCheck className='size-5' strokeWidth={1.6} />,
      title: t('home.gap.reason2.title'),
      desc: t('home.gap.reason2.desc'),
    },
    {
      icon: <CircleHelp className='size-5' strokeWidth={1.6} />,
      title: t('home.gap.reason3.title'),
      desc: t('home.gap.reason3.desc'),
    },
  ]

  return (
    <section
      id='information-gap'
      className={cn(
        'border-border/40 bg-muted/10 relative z-10 border-y px-6 py-20 md:py-24',
        props.className
      )}
    >
      <div className='mx-auto grid max-w-6xl gap-12 md:grid-cols-[0.92fr_1.08fr] md:items-start'>
        <AnimateInView>
          <p className='text-muted-foreground mb-3 text-xs font-medium tracking-widest uppercase'>
            {t('home.gap.kicker')}
          </p>
          <h2 className='max-w-xl text-2xl leading-tight font-bold tracking-normal md:text-4xl'>
            {t('home.gap.title')}
          </h2>
          <p className='text-muted-foreground mt-5 max-w-xl text-base leading-8'>
            {t('home.gap.description')}
          </p>
          <p className='text-muted-foreground/80 mt-5 max-w-xl text-sm leading-7'>
            {t('home.gap.sourceNote')}
          </p>
        </AnimateInView>

        <div className='grid gap-4'>
          {reasons.map((reason, index) => (
            <AnimateInView
              key={reason.title}
              delay={index * 120}
              animation='fade-left'
              className='group relative overflow-hidden rounded-lg border border-blue-200/70 bg-background/95 p-5 transition-colors hover:border-sky-400/60 dark:border-sky-300/12 dark:bg-[#071a33]/92'
            >
              <div className='flex gap-4'>
                <div className='text-sky-700 dark:text-sky-300'>
                  {reason.icon}
                </div>
                <div>
                  <h3 className='text-base font-semibold'>{reason.title}</h3>
                  <p className='text-muted-foreground mt-2 text-sm leading-7'>
                    {reason.desc}
                  </p>
                </div>
              </div>
            </AnimateInView>
          ))}
          <AnimateInView
            delay={360}
            animation='fade-left'
            className='rounded-lg border border-blue-200/70 bg-white/90 p-5 dark:border-sky-300/12 dark:bg-[#071a33]/88'
          >
            <GapLayerDiagram />
          </AnimateInView>
        </div>
      </div>
    </section>
  )
}

function GapLayerDiagram() {
  const { t } = useTranslation()
  const meters = [
    {
      label: t('home.gap.diagram.entry'),
      value: t('home.gap.diagram.entryValue'),
    },
    {
      label: t('home.gap.diagram.judgement'),
      value: t('home.gap.diagram.judgementValue'),
    },
    {
      label: t('home.gap.diagram.outcome'),
      value: t('home.gap.diagram.outcomeValue'),
    },
  ]

  return (
    <div>
      <div className='mb-4 flex items-center justify-between gap-3'>
        <p className='text-sm font-semibold'>{t('home.gap.diagram.title')}</p>
        <span className='rounded-md bg-cyan-500/10 px-2 py-1 text-[11px] font-medium text-cyan-700 dark:text-cyan-300'>
          {t('home.gap.diagram.status')}
        </span>
      </div>
      <div className='relative overflow-hidden rounded-lg border border-blue-200/60 bg-sky-500/[0.03] p-4 dark:border-sky-300/10'>
        <svg
          aria-hidden='true'
          className='h-[210px] w-full text-sky-500/55 dark:text-sky-300/45'
          viewBox='0 0 520 210'
        >
          <path
            className='ph01-gap-thread'
            d='M48 52 C98 52, 118 82, 168 104 C214 124, 270 104, 310 102'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
          />
          <path
            className='ph01-gap-thread'
            d='M48 104 C102 104, 122 104, 168 104 C214 104, 268 104, 310 102'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
          />
          <path
            className='ph01-gap-thread'
            d='M48 156 C98 156, 118 126, 168 104 C214 84, 270 102, 310 102'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
          />
          <path
            className='ph01-gap-branch ph01-gap-branch-1'
            d='M310 102 C358 72, 404 58, 470 48'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='2.5'
          />
          <path
            className='ph01-gap-branch ph01-gap-branch-2'
            d='M310 102 C360 104, 408 104, 470 104'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='2.5'
          />
          <path
            className='ph01-gap-branch ph01-gap-branch-3'
            d='M310 102 C356 138, 402 152, 470 164'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='2.5'
          />
          <circle className='ph01-gap-packet ph01-gap-packet-1' r='4.5' fill='currentColor' />
          <circle className='ph01-gap-packet ph01-gap-packet-2' r='4' fill='currentColor' />
          <circle className='ph01-gap-packet ph01-gap-packet-3' r='3.5' fill='currentColor' />
        </svg>

        <div className='pointer-events-none absolute inset-x-4 top-4 h-[210px]'>
          <div className='ph01-gap-node ph01-gap-node-entry absolute top-[76px] left-1 rounded-lg border border-blue-200/70 bg-background/92 px-3 py-2 dark:border-sky-300/12 dark:bg-[#071a33]'>
            <p className='text-xs font-semibold'>{t('home.gap.diagram.entry')}</p>
            <p className='text-muted-foreground mt-1 text-[11px]'>
              {t('home.gap.diagram.entryValue')}
            </p>
          </div>
          <div className='ph01-gap-node ph01-gap-node-judge absolute top-[72px] left-[45%] -translate-x-1/2 rounded-lg border border-blue-200/70 bg-background/92 px-3 py-2 dark:border-sky-300/12 dark:bg-[#071a33]'>
            <p className='text-xs font-semibold'>{t('home.gap.diagram.judgement')}</p>
            <p className='text-muted-foreground mt-1 text-[11px]'>
              {t('home.gap.diagram.judgementValue')}
            </p>
          </div>
          <div className='ph01-gap-node ph01-gap-node-outcome absolute top-[72px] right-1 rounded-lg border border-blue-200/70 bg-background/92 px-3 py-2 dark:border-sky-300/12 dark:bg-[#071a33]'>
            <p className='text-xs font-semibold'>{t('home.gap.diagram.outcome')}</p>
            <p className='text-muted-foreground mt-1 text-[11px]'>
              {t('home.gap.diagram.outcomeValue')}
            </p>
          </div>
        </div>

        <div className='relative grid gap-3'>
          {meters.map((meter, index) => (
            <div
              key={meter.label}
              className='flex items-center gap-3 rounded-md border border-blue-200/50 bg-background/80 px-3 py-2 text-sm dark:border-sky-300/10'
            >
              <span className='size-2 rounded-full bg-sky-500' />
              <span className='w-16 shrink-0 font-medium'>{meter.label}</span>
              <span className='relative h-1.5 flex-1 overflow-hidden rounded-full bg-blue-100 dark:bg-sky-950'>
                <span
                  className='ph01-gap-meter absolute inset-y-0 left-0 rounded-full bg-sky-500/70'
                  style={{
                    animationDelay: `${index * 520}ms`,
                    ['--gap-meter' as string]: `${index === 0 ? 86 : index === 1 ? 54 : 38}%`,
                  }}
                />
              </span>
              <span className='text-muted-foreground w-16 text-right text-xs'>
                {meter.value}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
