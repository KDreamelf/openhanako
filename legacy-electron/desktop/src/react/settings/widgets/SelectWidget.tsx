/**
 * SDW（轻量下拉选择组件）的 React 版本
 */
import React, { useState, useRef, useEffect, useCallback } from 'react';
import { createPortal } from 'react-dom';

export interface SelectOption {
  value: string;
  label: string;
  disabled?: boolean;
}

interface SelectWidgetProps {
  options: SelectOption[];
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
}

export function SelectWidget({ options, value, onChange, placeholder }: SelectWidgetProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popupRef = useRef<HTMLDivElement>(null);
  const [popupStyle, setPopupStyle] = useState<React.CSSProperties>({});

  const close = useCallback(() => setOpen(false), []);
  const updatePopupPosition = useCallback(() => {
    const trigger = triggerRef.current;
    if (!trigger) return;

    const rect = trigger.getBoundingClientRect();
    const popupEl = popupRef.current;
    const popupWidth = Math.max(rect.width, popupEl?.offsetWidth || 0);
    const popupHeight = popupEl?.offsetHeight || Math.min(options.length * 36 + 12, 280);
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;
    const gap = 6;

    let top = rect.bottom + gap;
    if (top + popupHeight > viewportHeight - 8) {
      top = Math.max(8, rect.top - popupHeight - gap);
    }

    let left = rect.left;
    if (left + popupWidth > viewportWidth - 8) {
      left = Math.max(8, viewportWidth - popupWidth - 8);
    }

    setPopupStyle({
      position: 'fixed',
      top,
      left,
      minWidth: rect.width,
      zIndex: 10000,
    });
  }, [options.length]);

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      const target = e.target as Node;
      if (ref.current?.contains(target) || popupRef.current?.contains(target)) return;
      close();
    };
    document.addEventListener('click', handler);
    return () => document.removeEventListener('click', handler);
  }, [open, close]);

  useEffect(() => {
    if (!open) return;
    updatePopupPosition();
    const rafId = window.requestAnimationFrame(updatePopupPosition);
    window.addEventListener('resize', updatePopupPosition);
    window.addEventListener('scroll', updatePopupPosition, true);
    return () => {
      window.cancelAnimationFrame(rafId);
      window.removeEventListener('resize', updatePopupPosition);
      window.removeEventListener('scroll', updatePopupPosition, true);
    };
  }, [open, updatePopupPosition]);

  const current = options.find(o => o.value === value);
  const displayText = current?.label || placeholder || '';
  const isPlaceholder = !current;

  return (
    <div className={`sdw${open ? ' open' : ''}`} ref={ref}>
      <button
        type="button"
        className="sdw-trigger"
        ref={triggerRef}
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span className={`sdw-value${isPlaceholder ? ' sdw-placeholder' : ''}`}>{displayText}</span>
        <span className="sdw-arrow">▾</span>
      </button>
      {open && typeof document !== 'undefined' && createPortal(
        <div
          className="sdw-popup sdw-popup-portal"
          ref={popupRef}
          style={popupStyle}
        >
          {options.map(item => (
            <button
              type="button"
              key={item.value}
              className={`sdw-option${item.value === value ? ' selected' : ''}${item.disabled ? ' disabled' : ''}`}
              onClick={() => {
                if (item.disabled) return;
                onChange(item.value);
                close();
              }}
            >
              {item.label}
            </button>
          ))}
        </div>,
        document.body,
      )}
    </div>
  );
}
