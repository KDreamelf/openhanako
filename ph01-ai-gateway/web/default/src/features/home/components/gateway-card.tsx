import { useTranslation } from 'react-i18next'
import { Separator } from '@/components/ui/separator'
import { getGatewayFeatures } from '../constants'

interface GatewayCardProps {
  logo: string
  systemName: string
}

/**
 * Central gateway card with features grid
 */
export function GatewayCard({ logo, systemName }: GatewayCardProps) {
  const { t } = useTranslation()
  const features = getGatewayFeatures(t)

  return (
    <div className='glass-3 group border-border/60 dark:border-border/30 relative overflow-hidden rounded-xl border p-10 shadow-[0_24px_80px_-56px_rgb(29_94_255_/_0.55)] transition-all duration-500 sm:p-12 dark:shadow-[0_24px_88px_-60px_rgb(120_215_255_/_0.45)]'>
      {/* Top gradient border effect */}
      <Separator className='absolute top-0 left-[10%] h-[2px] w-[80%] bg-gradient-to-r from-transparent via-sky-500/80 to-transparent' />

      {/* Subtle scanner highlight */}
      <div className='absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-cyan-400/50 to-transparent transition-all duration-500 group-hover:via-cyan-300/70' />

      <div className='relative'>
        {/* Gateway Header */}
        <div className='mb-8 flex items-center justify-center gap-3'>
          <img
            src={logo}
            alt={systemName}
            className='h-12 w-12 rounded-lg object-cover'
          />
          <h3 className='from-foreground to-foreground/70 bg-gradient-to-r bg-clip-text text-2xl font-bold text-transparent'>
            {systemName}
          </h3>
        </div>

        {/* Features Grid */}
        <div className='grid grid-cols-2 gap-3'>
          {features.map((feature, i) => (
            <div
              key={i}
              className='glass-morphism group/item border-border/40 dark:border-border/30 relative overflow-hidden rounded-lg border px-4 py-3.5 text-center shadow-sm transition-all duration-300 hover:scale-[1.02] hover:border-sky-500/40 hover:shadow-md'
            >
              <div className='absolute inset-0 bg-gradient-to-br from-sky-500/0 to-cyan-500/0 transition-all duration-300 group-hover/item:from-sky-500/10' />
              <span className='text-foreground/90 group-hover/item:text-foreground relative text-sm font-medium'>
                {feature}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
