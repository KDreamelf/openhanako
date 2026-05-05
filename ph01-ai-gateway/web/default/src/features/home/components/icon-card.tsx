import { getLobeIcon } from '@/lib/lobe-icon'
import { cn } from '@/lib/utils'

interface IconCardProps {
  iconName: string
  size?: number
  className?: string
}

/**
 * Reusable icon card component with glass morphism effect
 */
export function IconCard({ iconName, size = 32, className }: IconCardProps) {
  return (
    <div
      className={cn(
        'glass-morphism group/card border-border/50 dark:border-border/20',
        'relative overflow-hidden rounded-xl border p-5',
        'transition-all duration-500 hover:scale-105',
        className
      )}
    >
      <div className='absolute inset-x-4 top-0 h-px bg-gradient-to-r from-transparent via-sky-400/50 to-transparent opacity-0 transition-opacity duration-500 group-hover/card:opacity-100' />
      <div className='relative flex items-center justify-center'>
        {getLobeIcon(iconName, size)}
      </div>
    </div>
  )
}
