import React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const glowVariants = cva('absolute w-full', {
  variants: {
    variant: {
      top: 'top-0',
      above: '-top-[128px]',
      bottom: 'bottom-0',
      below: '-bottom-[128px]',
      center: 'top-[50%]',
    },
  },
  defaultVariants: {
    variant: 'top',
  },
})

export interface GlowProps
  extends
    React.HTMLAttributes<HTMLDivElement>,
    VariantProps<typeof glowVariants> {}

export function Glow({ className, variant, ...props }: GlowProps) {
  return (
    <div
      data-slot='glow'
      className={cn(glowVariants({ variant }), className)}
      {...props}
    >
      <div
        className={cn(
          'absolute left-1/2 h-px w-[72%] -translate-x-1/2 bg-gradient-to-r from-transparent via-sky-400/60 to-transparent opacity-[0.55]',
          variant === 'center' && '-translate-y-1/2'
        )}
      />
      <div
        className={cn(
          'absolute left-1/2 mt-4 h-px w-[42%] -translate-x-1/2 bg-gradient-to-r from-transparent via-cyan-300/40 to-transparent opacity-[0.45]',
          variant === 'center' && '-translate-y-1/2'
        )}
      />
    </div>
  )
}
