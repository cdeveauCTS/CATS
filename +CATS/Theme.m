classdef Theme
    % Theme
    %
    % CATS colours and type sizes, in one place.
    %
    % Brand colours are the 3TS palette, with the same meanings:
    %
    %   Primary (CTS Blue)    + white text   action / idle
    %   Success (CTS Green)   + black text   connected / PASS
    %   Warning (CTS Orange)  + black text   attention / FAIL
    %
    % These fills read well on both light and dark backgrounds, so they
    % are fixed. Everything else (figure, panels, labels, fields, axes)
    % is left on automatic colours so MATLAB's light/dark theme applies.
    %
    % Usage:
    %
    %   CATS.Theme.apply(fig, "dark");
    %   CATS.Theme.style(btn, "primary");
    %

    properties (Constant)

        Primary = [0 59 113]/255

        OnPrimary = [1 1 1]

        Success = [149 214 0]/255

        Warning = [255 131 0]/255

        OnStatus = [0 0 0]

        Neutral = [0.6 0.6 0.6]

        %
        % Type sizes (pt)
        %
        FontBase = 14

        FontLarge = 18

        FontHeading = 22

        FontSerial = 34

        FontDecision = 36

    end

    methods (Static)

        function apply(fig, mode)
            % Set the figure to "light" or "dark".

            arguments
                fig
                mode {mustBeMember(mode, ["light","dark"])}
            end

            fig.Theme = mode;

        end

        function style(component, role)
            % Apply a brand role to a button (or label / lamp):
            %   "primary" | "success" | "warning" | "neutral" | "auto"

            arguments
                component
                role {mustBeMember(role, ["primary","success","warning","neutral","auto"])}
            end

            switch role

                case "auto"

                    % Back to theme colours
                    if isprop(component, 'BackgroundColorMode')
                        component.BackgroundColorMode = "auto";
                    end

                    if isprop(component, 'FontColorMode')
                        component.FontColorMode = "auto";
                    end

                    return

                case "primary"
                    fill = CATS.Theme.Primary;
                    text = CATS.Theme.OnPrimary;

                case "success"
                    fill = CATS.Theme.Success;
                    text = CATS.Theme.OnStatus;

                case "warning"
                    fill = CATS.Theme.Warning;
                    text = CATS.Theme.OnStatus;

                case "neutral"
                    fill = CATS.Theme.Neutral;
                    text = CATS.Theme.OnStatus;

            end

            if isa(component, 'matlab.ui.control.Lamp')

                component.Color = fill;

                return

            end

            if isprop(component, 'BackgroundColor')
                component.BackgroundColor = fill;
            end

            if isprop(component, 'FontColor')
                component.FontColor = text;
            end

        end

        function [color, lineStyle] = trace(parameter)
            % Colour and line style for an S-parameter trace, the same on
            % every plot. Mid-brightness colours that read on light and
            % dark axes and stay clear of the green / orange limit lines.
            %
            %   transmission solid:  S21 blue, S31 teal
            %   reflection:          S11 magenta dashed, S22 red dotted,
            %                        S33 grey dash-dot

            switch upper(string(parameter))
                case "S21"
                    color = [30 120 220]/255;   lineStyle = '-';
                case "S31"
                    color = [0 165 165]/255;    lineStyle = '-';
                case "S11"
                    color = [200 60 200]/255;   lineStyle = '--';
                case "S22"
                    color = [225 40 60]/255;    lineStyle = ':';
                case "S33"
                    color = [140 140 140]/255;  lineStyle = '-.';
                otherwise
                    color = [120 100 200]/255;  lineStyle = '-';
            end

        end

        function color = passFail(tf)
            % Success colour for true, warning colour for false.

            if tf
                color = CATS.Theme.Success;
            else
                color = CATS.Theme.Warning;
            end

        end

    end

end
