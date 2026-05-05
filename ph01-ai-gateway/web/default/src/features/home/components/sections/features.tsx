import { BrainCircuit, GitBranch, ListChecks, Sparkles } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { AnimateInView } from '@/components/animate-in-view'

interface FeaturesProps {
  className?: string
}

export function Features(props: FeaturesProps) {
  const { t } = useTranslation()

  const experiencePoints = [
    t('home.experience.point1'),
    t('home.experience.point2'),
    t('home.experience.point3'),
    t('home.experience.point4'),
  ]

  const comparisons = [
    {
      label: t('home.skillCompare.row1.label'),
      skill: t('home.skillCompare.row1.skill'),
      experience: t('home.skillCompare.row1.experience'),
    },
    {
      label: t('home.skillCompare.row2.label'),
      skill: t('home.skillCompare.row2.skill'),
      experience: t('home.skillCompare.row2.experience'),
    },
    {
      label: t('home.skillCompare.row3.label'),
      skill: t('home.skillCompare.row3.skill'),
      experience: t('home.skillCompare.row3.experience'),
    },
  ]

  return (
    <section
      id='experience'
      className={cn('relative z-10 px-6 py-24 md:py-32', props.className)}
    >
      <div className='mx-auto max-w-6xl'>
        <div className='grid gap-14 lg:grid-cols-[0.9fr_1.1fr] lg:items-start'>
          <AnimateInView>
            <p className='text-muted-foreground mb-3 text-xs font-medium tracking-widest uppercase'>
              {t('home.experience.kicker')}
            </p>
            <h2 className='max-w-xl text-2xl leading-tight font-bold tracking-normal md:text-4xl'>
              {t('home.experience.title')}
            </h2>
            <p className='text-muted-foreground mt-5 max-w-xl text-base leading-8'>
              {t('home.experience.description')}
            </p>
          </AnimateInView>

          <AnimateInView
            animation='fade-left'
            className='rounded-lg border border-blue-200/70 bg-white/95 p-5 dark:border-sky-300/12 dark:bg-[#071a33]/92 md:p-6'
          >
            <div className='mb-6 flex items-center gap-3'>
              <div className='flex size-10 items-center justify-center rounded-lg bg-sky-500/10 text-sky-700 dark:text-sky-300'>
                <BrainCircuit className='size-5' strokeWidth={1.7} />
              </div>
              <div>
                <h3 className='text-lg font-semibold'>
                  {t('home.experience.cardTitle')}
                </h3>
                <p className='text-muted-foreground text-sm'>
                  {t('home.experience.cardSubtitle')}
                </p>
              </div>
            </div>
            <ExperienceProcessMap />
            <div className='grid gap-3 sm:grid-cols-2'>
              {experiencePoints.map((point, index) => (
                <div
                  key={point}
                  className='border-border/50 bg-background/70 rounded-lg border p-4'
                >
                  <div className='mb-3 flex items-center justify-between'>
                    <span className='font-mono text-xs text-sky-700 dark:text-sky-300'>
                      0{index + 1}
                    </span>
                    <Sparkles
                      className='size-4 text-cyan-600 dark:text-cyan-300'
                      strokeWidth={1.5}
                    />
                  </div>
                  <p className='text-sm leading-7'>{point}</p>
                </div>
              ))}
            </div>
          </AnimateInView>
        </div>

        <AnimateInView className='mt-20' threshold={0.1}>
          <div className='mb-8 flex flex-col justify-between gap-4 md:flex-row md:items-end'>
            <div>
              <p className='text-muted-foreground mb-3 text-xs font-medium tracking-widest uppercase'>
                {t('home.skillCompare.kicker')}
              </p>
              <h2 className='text-2xl leading-tight font-bold tracking-normal md:text-3xl'>
                {t('home.skillCompare.title')}
              </h2>
            </div>
            <p className='text-muted-foreground max-w-xl text-sm leading-7'>
              {t('home.skillCompare.description')}
            </p>
          </div>

          <div className='overflow-hidden rounded-lg border border-blue-200/70 bg-background/78 dark:border-sky-300/12'>
            <div className='hidden grid-cols-[0.76fr_1fr_1fr] border-b border-blue-200/70 bg-muted/30 text-sm font-semibold dark:border-sky-300/10 md:grid'>
              <div className='px-4 py-4'>{t('home.skillCompare.axis')}</div>
              <div className='border-l border-blue-200/70 px-4 py-4 dark:border-sky-300/10'>
                <span className='inline-flex items-center gap-2'>
                  <ListChecks className='size-4' strokeWidth={1.6} />
                  {t('home.skillCompare.skillColumn')}
                </span>
              </div>
              <div className='border-l border-blue-200/70 px-4 py-4 text-sky-700 dark:border-sky-300/10 dark:text-sky-300'>
                <span className='inline-flex items-center gap-2'>
                  <GitBranch className='size-4' strokeWidth={1.6} />
                  {t('home.skillCompare.experienceColumn')}
                </span>
              </div>
            </div>
            {comparisons.map((row) => (
              <div
                key={row.label}
                className='grid border-b border-blue-200/50 text-sm last:border-b-0 dark:border-sky-300/10 md:grid-cols-[0.76fr_1fr_1fr]'
              >
                <div className='bg-muted/20 px-4 py-4 font-semibold md:bg-transparent md:py-5'>
                  {row.label}
                </div>
                <div className='border-t border-blue-200/50 px-4 py-4 leading-7 dark:border-sky-300/10 md:border-t-0 md:border-l md:py-5'>
                  <p className='text-muted-foreground mb-1 text-xs font-medium md:hidden'>
                    {t('home.skillCompare.skillColumn')}
                  </p>
                  {row.skill}
                </div>
                <div className='border-t border-blue-200/50 px-4 py-4 leading-7 dark:border-sky-300/10 md:border-t-0 md:border-l md:py-5'>
                  <p className='text-muted-foreground mb-1 text-xs font-medium md:hidden'>
                    {t('home.skillCompare.experienceColumn')}
                  </p>
                  {row.experience}
                </div>
              </div>
            ))}
          </div>
        </AnimateInView>
      </div>
    </section>
  )
}

function ExperienceProcessMap() {
  const { t } = useTranslation()
  const stages = [
    {
      num: '01',
      label: t('home.experience.map.context'),
      className: 'left-[2%] top-8',
    },
    {
      num: '02',
      label: t('home.experience.map.questioning'),
      className: 'left-[2%] top-[118px]',
    },
    {
      num: '03',
      label: t('home.experience.map.evidence'),
      className: 'right-[2%] top-8',
    },
    {
      num: '04',
      label: t('home.experience.map.boundary'),
      className: 'right-[2%] top-[118px]',
    },
  ]

  return (
    <div className='mb-5 overflow-hidden rounded-lg border border-blue-200/60 bg-sky-500/[0.03] p-4 dark:border-sky-300/10'>
      <div className='ph01-process-board relative min-h-[236px]'>
        <svg
          aria-hidden='true'
          className='absolute inset-0 h-full w-full text-sky-500/50 dark:text-sky-300/42'
          viewBox='0 0 620 236'
        >
          <path
            className='ph01-process-thread'
            d='M58 62 C128 112, 120 154, 146 164 C238 224, 344 18, 474 62 C540 84, 514 140, 574 166'
            fill='none'
            stroke='currentColor'
            strokeWidth='1.5'
          />
          <path
            className='ph01-process-active'
            d='M58 62 C128 112, 120 154, 146 164 C238 224, 344 18, 474 62 C540 84, 514 140, 574 166'
            fill='none'
            stroke='currentColor'
            strokeLinecap='round'
            strokeWidth='3'
          />
          <circle className='ph01-process-cursor' r='5' fill='currentColor' />
        </svg>
        {stages.map((stage, index) => (
          <div
            key={stage.num}
            className={cn(
              'ph01-process-step absolute w-[132px] rounded-lg border border-blue-200/70 bg-background/92 px-3 py-2 shadow-[0_10px_26px_-24px_rgba(29,78,216,0.45)] dark:border-sky-300/12 dark:bg-[#071a33]',
              stage.className
            )}
            style={{ animationDelay: `${index * 820}ms` }}
          >
            <div className='flex items-center justify-between gap-2'>
              <span className='font-mono text-[11px] text-sky-700 dark:text-sky-300'>
                {stage.num}
              </span>
              <span className='h-1.5 w-8 overflow-hidden rounded-full bg-blue-100 dark:bg-sky-950'>
                <span
                  className='ph01-process-mini-scan block h-full rounded-full bg-sky-500/70'
                  style={{ animationDelay: `${index * 820}ms` }}
                />
              </span>
            </div>
            <p className='mt-2 text-xs leading-4 font-medium'>{stage.label}</p>
          </div>
        ))}
        <div className='ph01-process-result absolute bottom-3 left-1/2 w-[172px] -translate-x-1/2 rounded-lg border border-sky-300/50 bg-sky-500/10 px-4 py-3 text-center'>
          <p className='text-xs font-medium text-sky-700 dark:text-sky-200'>
            {t('home.experience.map.resultTop')}
          </p>
          <p className='mt-1 text-sm font-semibold'>
            {t('home.experience.map.resultBottom')}
          </p>
        </div>
      </div>
    </div>
  )
}
