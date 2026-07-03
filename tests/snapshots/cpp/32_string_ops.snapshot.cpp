
namespace {


} // namespace

int main() {
    auto s = BallDyn("Hello, World!"s);
    std::cout << ball_to_string(ball_to_string(ball_length(s))) << std::endl;
    std::cout << ball_to_string([](std::string s){std::transform(s.begin(),s.end(),s.begin(),::toupper);return s;}(s)) << std::endl;
    std::cout << ball_to_string([](std::string s){std::transform(s.begin(),s.end(),s.begin(),::tolower);return s;}(s)) << std::endl;
    std::cout << ball_to_string([](const std::string& s){auto a=s.find_first_not_of(" \t\n\r"),b=s.find_last_not_of(" \t\n\r");return a==std::string::npos?std::string():s.substr(a,b-a+1);}(s)) << std::endl;
    std::cout << ball_to_string((("Hello"s + ", "s) + "World!"s)) << std::endl;
    return 0;
}
