import { useQuery } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { AlertTriangle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { getUnconfiguredBillingModels } from '../../api'

type UnconfiguredBillingBannerProps = {
  enabled: boolean
}

export function UnconfiguredBillingBanner({
  enabled,
}: UnconfiguredBillingBannerProps) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data } = useQuery({
    queryKey: ['models', 'unconfigured-billing'],
    queryFn: getUnconfiguredBillingModels,
    enabled,
    staleTime: 30_000,
  })

  const models = data?.data || []
  if (!enabled || models.length === 0) return null

  return (
    <Alert
      variant='destructive'
      className='border-destructive/70 bg-destructive/10'
    >
      <AlertTriangle className='h-4 w-4' />
      <AlertTitle>{t('存在未配置计费的模型，当前正在免费提供服务')}</AlertTitle>
      <AlertDescription className='flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between'>
        <div className='min-w-0'>
          <p>
            {t(
              '{{count}} enabled channel models have no billing configuration.',
              { count: models.length }
            )}
          </p>
          <p className='truncate text-xs'>
            {models.slice(0, 8).join(', ')}
            {models.length > 8
              ? t(' and {{count}} more', { count: models.length - 8 })
              : ''}
          </p>
        </div>
        <Button
          type='button'
          variant='destructive'
          size='sm'
          className='shrink-0'
          onClick={() =>
            void navigate({
              to: '/system-settings/models/$section',
              params: { section: 'ratio' },
            })
          }
        >
          {t('Configure now')}
        </Button>
      </AlertDescription>
    </Alert>
  )
}
