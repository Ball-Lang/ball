
namespace {


} // namespace

int main() {
    auto a = BallDyn(static_cast<int64_t>(5));
    auto b = BallDyn(static_cast<int64_t>(3));
    std::cout << ball_to_string(ball_to_string((a > b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a < b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a >= a))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a == a))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a != b))) << std::endl;
    return 0;
}
