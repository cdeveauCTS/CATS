classdef SerialNumber
    % SerialNumber
    %
    % Serial numbers are text ending in a number, e.g. "1235-0042" or
    % "WO3296-17". The trailing number increments and keeps its zero
    % padding (0099 -> 0100; 99 -> 100).
    %
    % Usage:
    %
    %   CATS.SerialNumber.next("1235-0042")      % "1235-0043"
    %   CATS.SerialNumber.isValid("1235-")       % false
    %

    methods (Static)

        function serial = next(serial)

            serial = strtrim(string(serial));

            tokens = regexp(serial, '^(.*?)(\d+)$', 'tokens', 'once');

            if isempty(tokens)
                error('CATS:BadSerial', ...
                    'Serial "%s" must end in a number.', serial);
            end

            prefix = tokens(1);
            digits = tokens(2);

            value = str2double(digits) + 1;

            width = strlength(digits);

            serial = prefix + sprintf('%0*d', width, value);

        end

        function tf = isValid(serial)
            % Ends in a number, and only contains characters that are
            % safe in Windows file and folder names.

            serial = strtrim(string(serial));

            tf = strlength(serial) > 0 && ...
                ~isempty(regexp(serial, '\d$', 'once')) && ...
                isempty(regexp(serial, '[<>:"/\\|?*\s]', 'once'));

        end

    end

end
