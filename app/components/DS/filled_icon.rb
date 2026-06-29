class DS::FilledIcon < DesignSystemComponent
  attr_reader :icon, :text, :hex_color, :size, :rounded, :variant, :description, :aria_hidden

  VARIANTS = %i[default text surface container inverse].freeze

  SIZES = {
    sm: {
      container_size: "w-6 h-6",
      container_radius: "rounded-md",
      icon_size: "sm",
      text_size: "text-xs"
    },
    md: {
      container_size: "w-8 h-8",
      container_radius: "rounded-lg",
      icon_size: "md",
      text_size: "text-xs"
    },
    lg: {
      container_size: "w-9 h-9",
      container_radius: "rounded-xl",
      icon_size: "lg",
      text_size: "text-sm"
    }
  }.freeze

  LETTERMARK_STOP_WORDS = %w[the of and for at by in on to a an ltd llc inc co].freeze

  def initialize(variant: :default, icon: nil, text: nil, hex_color: nil, size: "md", rounded: false, description: nil, aria_hidden: nil)
    @variant = variant.to_sym
    @icon = icon
    @text = text
    @hex_color = hex_color
    @size = size.to_sym
    @rounded = rounded
    @description = description.presence
    @aria_hidden = aria_hidden.nil? ? @description.blank? : aria_hidden
  end

  def container_classes
    class_names(
      "flex justify-center items-center shrink-0",
      size_classes,
      radius_classes,
      transparent? ? "border" : solid_bg_class
    )
  end

  def icon_size
    SIZES[size][:icon_size]
  end

  def text_classes
    chars = display_text&.length || 1
    size_class = case size
                 when :sm
                   chars <= 1 ? "text-xs" : chars <= 2 ? "text-[9px]" : "text-[8px]"
                 when :md
                   chars <= 1 ? "text-xs" : chars <= 2 ? "text-xs" : "text-[9px]"
                 when :lg
                   chars <= 1 ? "text-sm" : chars <= 2 ? "text-xs" : "text-[10px]"
                 else
                   SIZES[size][:text_size]
                 end
    class_names("text-center font-medium uppercase", size_class)
  end

  def display_text
    return nil unless text
    lettermark_text(text)
  end

  def container_styles
    <<~STYLE.strip
      background-color: #{transparent_bg_color};
      border-color: #{transparent_border_color};
      color: #{custom_fg_color};
    STYLE
  end

  def transparent?
    variant.in?(%i[default text])
  end

  private
    def solid_bg_class
      case variant
      when :surface
        "bg-surface-inset"
      when :container
        "bg-container-inset"
      when :inverse
        "bg-container"
      end
    end

    def size_classes
      SIZES[size][:container_size]
    end

    def radius_classes
      rounded ? "rounded-full" : SIZES[size][:container_radius]
    end

    def custom_fg_color
      hex_color.presence || "#94a3b8"
    end

    def transparent_bg_color
      "color-mix(in oklab, #{custom_fg_color} 10%, transparent)"
    end

    def transparent_border_color
      "color-mix(in oklab, #{custom_fg_color} 10%, transparent)"
    end

    def lettermark_text(name)
      return "?" if name.blank?
      n = name.strip
      return n.upcase if n.length <= 5

      words = n.split(/[\s\-_&\/\.]+/)
      significant = words.reject { |w| LETTERMARK_STOP_WORDS.include?(w.downcase) }
      significant = words if significant.empty?

      initials = ""
      significant.each do |word|
        break if initials.length >= 3
        initials += word[0].upcase
        word[1..].each_char do |c|
          break if initials.length >= 3
          initials += c if c.match?(/[A-Z]/)
        end
      end

      initials.slice(0, 3).presence || name.first.upcase
    end
end
