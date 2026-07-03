
namespace {


} // namespace

int main() {
    auto s = BallDyn("  hello world  "s);
    std::cout << ball_to_string([](const std::string& s){auto a=s.find_first_not_of(" \t\n\r"),b=s.find_last_not_of(" \t\n\r");return a==std::string::npos?std::string():s.substr(a,b-a+1);}(s)) << std::endl;
    std::cout << ball_to_string([](std::string s){std::transform(s.begin(),s.end(),s.begin(),::toupper);return s;}("abc"s)) << std::endl;
    std::cout << ball_to_string([](std::string s){std::transform(s.begin(),s.end(),s.begin(),::tolower);return s;}("XYZ"s)) << std::endl;
    std::cout << ball_to_string(ball_to_string(ball_length("padme"s))) << std::endl;
    std::cout << ball_to_string((("a"s + "b"s) + "c"s)) << std::endl;
    return 0;
}
